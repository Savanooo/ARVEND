package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Kendi masrafı (migration 0066, ürün sahibi kararı 2026-10-07: "masrafı
// herkes girsin ama bekleme/inceleme olsun; onayı sadece yönetici, en üst
// kişi yapacak"). projects.expenses.create taşıyan ama projects.finance.
// manage taşımayan kişi (sahadaki usta, Saha/Proje Yöneticisi rolü):
//
//   - masrafı yalnızca TEMEL alanlarla girer: kategori, açıklama, tutar,
//     para birimi, tarih, KDV oranı, kime ödendiği, fiş/fatura no, not.
//     Bunlar elindeki fişte yazandır. Ek iş / bütçe kalemi / maliyet kodu
//     bağı ise maliyetin NEREYE yazılacağı kararıdır -- finansın işi; o
//     listeleri okuyamayan kişi doğru seçimi de yapamaz.
//   - YALNIZCA kendi girdiği, onay bekleyen ya da reddedilen masrafı
//     düzeltir veya geri çeker. Onaylanmış masraf artık gerçekleşen
//     maliyettedir; onu yalnızca finans yetkilisi değiştirir.
//   - yalnızca kendi masraflarını görür (ListMyExpenses) -- başkasının
//     masrafı, toplamlar ve finans özeti projects.finance.read ister.
//
// projects.finance.manage sahibinin bugünkü hakları (her masrafı her
// durumda düzenleme/iptal, bağları yazma) aynen kalır.

var (
	// ErrExpenseFinanceLinkForbidden: finans yetkisi olmayan kişi masrafı
	// ek işe / bütçe kalemine / maliyet koduna bağlamaya çalıştı. Sessizce
	// yok saymak yerine reddedilir: seçimi yapan istemci, seçiminin
	// kaydedildiğini sanmasın (mobil formu bu alanları zaten göstermez).
	ErrExpenseFinanceLinkForbidden = errors.New("masrafı ek işe, bütçe kalemine veya maliyet koduna bağlamak finans yönetme yetkisi ister; bu alanları boş bırakın")
	// ErrExpenseNotOwn: başkasının masrafını düzeltme/geri çekme denemesi.
	ErrExpenseNotOwn = errors.New("yalnızca kendi girdiğiniz masrafı düzenleyebilir veya geri çekebilirsiniz")
	// ErrExpenseApprovedLocked: kişi kendi masrafını onaylandıktan sonra
	// değiştirmeye çalıştı.
	ErrExpenseApprovedLocked = errors.New("onaylanmış masraf yalnızca finans yetkilisi tarafından düzenlenebilir veya iptal edilebilir")
)

// checkOwnExpenseLinks: kısıtlı yazar (ExpenseInput.OwnOnly) finans
// bağlarını DEĞİŞTİREMEZ. Oluştururken üçü de boş olmalı. Düzenlerken boş
// ya da kayıttaki değerin aynısı kabul edilir (ikisi de "dokunma" demek):
// istemci okuduğu satırı aynen geri gönderebilir, finansın bu arada
// eklediği bağ da sahadaki düzeltmede kaybolmaz. Farklı bir değer = 403.
func checkOwnExpenseLinks(in ExpenseInput, stored *sqlc.ProjectExpense) error {
	same := func(sent string, have pgtype.UUID) bool {
		sent = strings.TrimSpace(sent)
		return sent == "" || (stored != nil && have.Valid && strings.EqualFold(sent, have.String()))
	}
	var co, cc, bl pgtype.UUID
	if stored != nil {
		co, cc, bl = stored.ChangeOrderID, stored.CostCodeID, stored.BudgetLineID
	}
	if !same(in.ChangeOrderID, co) || !same(in.CostCodeID, cc) || !same(in.BudgetLineID, bl) {
		return ErrExpenseFinanceLinkForbidden
	}
	return nil
}

// ownWritableExpense: kısıtlı yazarın dokunabileceği masrafı okur --
// kendisinin girdiği, iptal edilmemiş, onay bekleyen ya da reddedilmiş.
// Çağıran requireOpenProject ile proje satırını KİLİTLEMİŞ olmalı: masrafa
// yazan her yol (giriş, düzenleme, iptal, onay/ret) önce o satırı kilitler,
// bu yüzden burada okunan durum yazıma kadar değişemez (eşzamanlı bir onay
// ya önce biter ve burada "onaylanmış" görülür, ya da bu düzenlemeden sonra
// sıraya girer).
func ownWritableExpense(ctx context.Context, txq *sqlc.Queries, eid, pid, orgID pgtype.UUID, userID string) (sqlc.ProjectExpense, error) {
	row, err := txq.GetExpense(ctx, sqlc.GetExpenseParams{ID: eid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.ProjectExpense{}, ErrExpenseNotFound
		}
		return sqlc.ProjectExpense{}, err
	}
	actor := actorUUID(userID)
	switch {
	case !actor.Valid || !row.CreatedBy.Valid || row.CreatedBy != actor:
		return sqlc.ProjectExpense{}, ErrExpenseNotOwn
	case row.VoidedAt.Valid:
		return sqlc.ProjectExpense{}, ErrAlreadyVoided
	case row.ApprovalStatus == domain.ExpenseApprovalApproved:
		return sqlc.ProjectExpense{}, ErrExpenseApprovedLocked
	}
	return row, nil
}

// WithdrawOwnExpense: kişi kendi girdiği, onay bekleyen ya da reddedilen
// masrafı geri çeker. Kayıt silinmez; VoidExpense ile aynı iptal izi
// (voided_by = giren kişi) -- "geri çekildi" ile "finans iptal etti" bu
// alandan ayrılır. Onaylanmış masraf ErrExpenseApprovedLocked.
func (s *ProjectService) WithdrawOwnExpense(ctx context.Context, projectID, expenseID, organizationID, userID, reason string) (*domain.Expense, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	eid, err := repository.StringToUUID(expenseID)
	if err != nil {
		return nil, ErrExpenseNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	if _, err := ownWritableExpense(ctx, txq, eid, pid, orgID, userID); err != nil {
		return nil, err
	}
	reason = strings.TrimSpace(reason)
	row, err := txq.VoidExpense(ctx, sqlc.VoidExpenseParams{
		ID: eid, OrganizationID: orgID, VoidedBy: actorUUID(userID), VoidReason: reason, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventExpenseVoided, actorUUID(userID),
		map[string]any{"expense_id": expenseID, "reason": reason, "withdrawn": true}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// ListMyExpenses: kişinin kendi girdiği masraflar (en yeni giriş önce, en
// fazla domain.MyExpensesLimit). projectID boşsa tüm erişebildiği projeler;
// restrictToUserID dolu ise (üyelikle sınırlı rol) yalnızca üyesi olduğu
// projeler -- bkz. ListMyExpenses SQL notu.
func (s *ProjectService) ListMyExpenses(ctx context.Context, organizationID, userID, projectID, restrictToUserID string) ([]domain.MyExpense, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	uid, err := repository.StringToUUID(userID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	var pid pgtype.UUID
	if strings.TrimSpace(projectID) != "" {
		if pid, err = repository.StringToUUID(projectID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	var restrict pgtype.UUID
	if restrictToUserID != "" {
		if restrict, err = repository.StringToUUID(restrictToUserID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	rows, err := s.q.ListMyExpenses(ctx, sqlc.ListMyExpensesParams{
		OrganizationID: orgID, CreatedBy: uid, ProjectID: pid, RestrictToUserID: restrict,
		RowLimit: domain.MyExpensesLimit,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.MyExpense, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainMyExpense(r)
	}
	return out, nil
}
