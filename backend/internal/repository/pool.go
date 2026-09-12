// Package repository, sqlc'nin ürettiği kodu (repository/sqlc) domain
// katmanına bağlar: pgx havuzunu kurar ve sqlc modellerini domain
// nesnelerine çevirir (pgtype.UUID/Timestamptz gibi veritabanı detaylarının
// servis/handler katmanına sızmaması için).
package repository

import (
	"context"
	"encoding/json"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func NewPool(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	return pgxpool.New(ctx, databaseURL)
}

func ToDomainCustomer(c sqlc.Customer) domain.Customer {
	return domain.Customer{
		ID:             c.ID.String(),
		OrganizationID: c.OrganizationID.String(),
		Name:           c.Name,
		Phone:          c.Phone,
		Email:          c.Email,
		Address:        c.Address,
		TaxOffice:      c.TaxOffice,
		TaxNumber:      c.TaxNumber,
		Notes:          c.Notes,
		IsActive:       c.IsActive,
		CreatedAt:      c.CreatedAt.Time,
		UpdatedAt:      c.UpdatedAt.Time,
	}
}

func ToDomainOrganization(o sqlc.Organization) domain.Organization {
	return domain.Organization{
		ID:        o.ID.String(),
		Name:      o.Name,
		Slug:      o.Slug,
		IsActive:  o.IsActive,
		CreatedAt: o.CreatedAt.Time,
		UpdatedAt: o.UpdatedAt.Time,
	}
}

func ToDomainUser(u sqlc.User) domain.User {
	du := domain.User{
		ID:             u.ID.String(),
		OrganizationID: u.OrganizationID.String(),
		Username:       u.Username,
		PasswordHash:   u.PasswordHash,
		FullName:       u.FullName,
		Role:           domain.Role(u.Role),
		IsActive:       u.IsActive,
		CreatedAt:      u.CreatedAt.Time,
		UpdatedAt:      u.UpdatedAt.Time,
	}
	if u.LastLoginAt.Valid {
		t := u.LastLoginAt.Time
		du.LastLoginAt = &t
	}
	return du
}

func StringToUUID(s string) (pgtype.UUID, error) {
	var id pgtype.UUID
	err := id.Scan(s)
	return id, err
}

func ToDomainProduct(p sqlc.Product) domain.Product {
	dp := domain.Product{
		ID:             p.ID.String(),
		OrganizationID: p.OrganizationID.String(),
		Name:           p.Name,
		NormalizedName: p.NormalizedName,
		Unit:           p.Unit,
		UnitPrice:      NumericToFloat64(p.UnitPrice),
		Description:    p.Description,
		Category:       p.Category,
		CreatedAt:      p.CreatedAt.Time,
		UpdatedAt:      p.UpdatedAt.Time,
	}
	if p.Source != nil {
		dp.Source = *p.Source
	}
	if p.SourcePrice.Valid {
		v := NumericToFloat64(p.SourcePrice)
		dp.SourcePrice = &v
	}
	return dp
}

func NumericToFloat64(n pgtype.Numeric) float64 {
	f, err := n.Float64Value()
	if err != nil || !f.Valid {
		return 0
	}
	return f.Float64
}

func Float64ToNumeric(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.Scan(strconv.FormatFloat(f, 'f', 2, 64))
	return n
}

// ToDomainOfferBase, offers tablosunun kimlik+lifecycle alanlarını
// dönüştürür -- içerik (müşteri, kalemler, toplamlar) dahil değildir,
// bkz. MergeOfferRevision.
func ToDomainOfferBase(o sqlc.Offer) domain.Offer {
	do := domain.Offer{
		ID:             o.ID.String(),
		OrganizationID: o.OrganizationID.String(),
		OfferNo:        o.OfferNo,
		OfferDate:      o.OfferDate.Time,
		Status:         o.Status,
		IsPassive:      o.IsPassive,
		CreatedAt:      o.CreatedAt.Time,
		UpdatedAt:      o.UpdatedAt.Time,
	}
	if o.CurrentRevisionID.Valid {
		do.CurrentRevisionID = o.CurrentRevisionID.String()
	}
	if o.CreatedBy.Valid {
		s := o.CreatedBy.String()
		do.CreatedBy = &s
	}
	return do
}

func ToDomainOfferRevision(r sqlc.OfferRevision) domain.OfferRevision {
	dr := domain.OfferRevision{
		ID:              r.ID.String(),
		OrganizationID:  r.OrganizationID.String(),
		OfferID:         r.OfferID.String(),
		RevisionNo:      int(r.RevisionNo),
		CustomerName:    r.CustomerName,
		CustomerPhone:   r.CustomerPhone,
		CustomerEmail:   r.CustomerEmail,
		CustomerAddress: r.CustomerAddress,
		Subtotal:        NumericToFloat64(r.Subtotal),
		DiscountType:    r.DiscountType,
		DiscountValue:   NumericToFloat64(r.DiscountValue),
		DiscountAmount:  NumericToFloat64(r.DiscountAmount),
		VatRate:         NumericToFloat64(r.VatRate),
		VatAmount:       NumericToFloat64(r.VatAmount),
		GrandTotal:      NumericToFloat64(r.GrandTotal),
		Currency:        r.Currency,
		Notes:           r.Notes,
		Status:          r.Status,
		CreatedAt:       r.CreatedAt.Time,
	}
	if r.ValidUntil.Valid {
		t := r.ValidUntil.Time
		dr.ValidUntil = &t
	}
	if r.CustomerID.Valid {
		s := r.CustomerID.String()
		dr.CustomerID = &s
	}
	if r.CreatedBy.Valid {
		s := r.CreatedBy.String()
		dr.CreatedBy = &s
	}
	return dr
}

func ToDomainOfferRevisionItem(i sqlc.OfferRevisionItem) domain.OfferItem {
	di := domain.OfferItem{
		ID:            i.ID.String(),
		ProductName:   i.ProductName,
		Quantity:      NumericToFloat64(i.Quantity),
		UnitPrice:     NumericToFloat64(i.UnitPrice),
		DiscountType:  i.DiscountType,
		DiscountValue: NumericToFloat64(i.DiscountValue),
		LineTotal:     NumericToFloat64(i.LineTotal),
		SortOrder:     int(i.SortOrder),
	}
	if i.ProductID.Valid {
		s := i.ProductID.String()
		di.ProductID = &s
	}
	return di
}

// ToDomainOfferListItem, ListOffers'ın JOIN'li satırını (offers +
// current revizyondan customer_name/grand_total/revision_no) liste
// görünümü için yeterli bir Offer'a çevirir -- her satır için ayrı bir
// revizyon sorgusuna gerek kalmaz.
func ToDomainOfferListItem(r sqlc.ListOffersRow) domain.Offer {
	o := domain.Offer{
		ID:             r.ID.String(),
		OrganizationID: r.OrganizationID.String(),
		OfferNo:        r.OfferNo,
		OfferDate:      r.OfferDate.Time,
		Status:         r.Status,
		IsPassive:      r.IsPassive,
		CreatedAt:      r.CreatedAt.Time,
		UpdatedAt:      r.UpdatedAt.Time,
		RevisionNo:     int(r.RevisionNo),
		CustomerName:   r.CustomerName,
		GrandTotal:     NumericToFloat64(r.GrandTotal),
	}
	if r.CurrentRevisionID.Valid {
		o.CurrentRevisionID = r.CurrentRevisionID.String()
	}
	if r.CreatedBy.Valid {
		s := r.CreatedBy.String()
		o.CreatedBy = &s
	}
	return o
}

// MergeOfferRevision, kimlik+lifecycle taşıyan Offer'ı, mevcut
// revizyonunun içeriğiyle birleştirip API'nin beklediği "düz" görünümü
// üretir.
func MergeOfferRevision(base domain.Offer, rev domain.OfferRevision, items []domain.OfferItem) domain.Offer {
	base.RevisionNo = rev.RevisionNo
	base.CustomerID = rev.CustomerID
	base.CustomerName = rev.CustomerName
	base.CustomerPhone = rev.CustomerPhone
	base.CustomerEmail = rev.CustomerEmail
	base.CustomerAddress = rev.CustomerAddress
	base.ValidUntil = rev.ValidUntil
	base.Subtotal = rev.Subtotal
	base.DiscountType = rev.DiscountType
	base.DiscountValue = rev.DiscountValue
	base.DiscountAmount = rev.DiscountAmount
	base.VatRate = rev.VatRate
	base.VatAmount = rev.VatAmount
	base.GrandTotal = rev.GrandTotal
	base.Currency = rev.Currency
	base.Notes = rev.Notes
	base.Items = items
	return base
}

func TimeToDate(t time.Time) pgtype.Date {
	return pgtype.Date{Time: t, Valid: true}
}

func ToDomainEmployee(e sqlc.Employee) domain.Employee {
	de := domain.Employee{
		ID:             e.ID.String(),
		OrganizationID: e.OrganizationID.String(),
		FullName:       e.FullName,
		Phone:          e.Phone,
		Position:       e.Position,
		IsActive:       e.IsActive,
		Description:    e.Description,
		CreatedAt:      e.CreatedAt.Time,
		UpdatedAt:      e.UpdatedAt.Time,
	}
	if e.Salary.Valid {
		v := NumericToFloat64(e.Salary)
		de.Salary = &v
	}
	if e.DailyWage.Valid {
		v := NumericToFloat64(e.DailyWage)
		de.DailyWage = &v
	}
	if e.StartDate.Valid {
		t := e.StartDate.Time
		de.StartDate = &t
	}
	return de
}

func FloatPtrToNumeric(f *float64) pgtype.Numeric {
	if f == nil {
		return pgtype.Numeric{}
	}
	return Float64ToNumeric(*f)
}

func TimePtrToDate(t *time.Time) pgtype.Date {
	if t == nil {
		return pgtype.Date{}
	}
	return pgtype.Date{Time: *t, Valid: true}
}

func ToDomainAttendance(a sqlc.AttendanceLog) domain.AttendanceLog {
	return domain.AttendanceLog{
		ID:             a.ID.String(),
		OrganizationID: a.OrganizationID.String(),
		EmployeeID:     a.EmployeeID.String(),
		Date:           a.Date.Time,
		CheckIn:        a.CheckIn,
		CheckOut:       a.CheckOut,
		WorkHours:      NumericToFloat64(a.WorkHours),
		Status:         a.Status,
		Note:           a.Note,
		CreatedAt:      a.CreatedAt.Time,
	}
}

func ToDomainAttendanceRow(r sqlc.ListAttendanceByMonthRow) domain.AttendanceLog {
	return domain.AttendanceLog{
		ID:             r.ID.String(),
		OrganizationID: r.OrganizationID.String(),
		EmployeeID:     r.EmployeeID.String(),
		EmployeeName:   r.EmployeeName,
		Date:           r.Date.Time,
		CheckIn:        r.CheckIn,
		CheckOut:       r.CheckOut,
		WorkHours:      NumericToFloat64(r.WorkHours),
		Status:         r.Status,
		Note:           r.Note,
		CreatedAt:      r.CreatedAt.Time,
	}
}

func ToDomainProject(p sqlc.Project) domain.Project {
	dp := domain.Project{
		ID:               p.ID.String(),
		OrganizationID:   p.OrganizationID.String(),
		ProjectNo:        p.ProjectNo,
		Name:             p.Name,
		ProjectType:      p.ProjectType,
		SourceOfferID:    p.SourceOfferID.String(),
		SourceRevisionID: p.SourceRevisionID.String(),
		CustomerName:     p.CustomerName,
		CustomerPhone:    p.CustomerPhone,
		CustomerEmail:    p.CustomerEmail,
		CustomerAddress:  p.CustomerAddress,
		ContractAmount:   NumericToFloat64(p.ContractAmount),
		Currency:         p.Currency,
		Status:           p.Status,
		Description:      p.Description,
		InternalNotes:    p.InternalNotes,
		CreatedAt:        p.CreatedAt.Time,
		UpdatedAt:        p.UpdatedAt.Time,
	}
	if p.CustomerID.Valid {
		s := p.CustomerID.String()
		dp.CustomerID = &s
	}
	if p.StartDate.Valid {
		t := p.StartDate.Time
		dp.StartDate = &t
	}
	if p.EndDate.Valid {
		t := p.EndDate.Time
		dp.EndDate = &t
	}
	if p.CreatedBy.Valid {
		s := p.CreatedBy.String()
		dp.CreatedBy = &s
	}
	return dp
}

// ToDomainProjectListItem, ListProjects'in JOIN'li satırını (projects +
// kaynak teklifin offer_no/revision_no'su) domain nesnesine çevirir.
func ToDomainProjectListItem(r sqlc.ListProjectsRow) domain.Project {
	dp := ToDomainProject(sqlc.Project{
		ID: r.ID, OrganizationID: r.OrganizationID, ProjectNo: r.ProjectNo, Name: r.Name,
		ProjectType: r.ProjectType, SourceOfferID: r.SourceOfferID, SourceRevisionID: r.SourceRevisionID,
		CustomerID: r.CustomerID, CustomerName: r.CustomerName, CustomerPhone: r.CustomerPhone,
		CustomerEmail: r.CustomerEmail, CustomerAddress: r.CustomerAddress,
		ContractAmount: r.ContractAmount, Currency: r.Currency, Status: r.Status,
		StartDate: r.StartDate, EndDate: r.EndDate, Description: r.Description,
		InternalNotes: r.InternalNotes, CreatedBy: r.CreatedBy, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
	})
	dp.SourceOfferNo = r.OfferNo
	dp.SourceRevisionNo = int(r.RevisionNo)
	return dp
}

func TimePtrToTimestamptz(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}

func ToDomainOfferShareLink(l sqlc.OfferShareLink) domain.OfferShareLink {
	dl := domain.OfferShareLink{
		ID:             l.ID.String(),
		OrganizationID: l.OrganizationID.String(),
		OfferID:        l.OfferID.String(),
		RevisionID:     l.RevisionID.String(),
		Token:          l.Token.String(),
		CreatedAt:      l.CreatedAt.Time,
	}
	if l.CreatedBy.Valid {
		s := l.CreatedBy.String()
		dl.CreatedBy = &s
	}
	if l.ExpiresAt.Valid {
		t := l.ExpiresAt.Time
		dl.ExpiresAt = &t
	}
	if l.RevokedAt.Valid {
		t := l.RevokedAt.Time
		dl.RevokedAt = &t
	}
	return dl
}

func ToDomainOfferEvent(e sqlc.OfferEvent) domain.OfferEvent {
	de := domain.OfferEvent{
		ID:             e.ID.String(),
		OrganizationID: e.OrganizationID.String(),
		OfferID:        e.OfferID.String(),
		EventType:      e.EventType,
		IPAddress:      e.IpAddress,
		UserAgent:      e.UserAgent,
		CreatedAt:      e.CreatedAt.Time,
	}
	if e.RevisionID.Valid {
		s := e.RevisionID.String()
		de.RevisionID = &s
	}
	if e.UserID.Valid {
		s := e.UserID.String()
		de.UserID = &s
	}
	if len(e.Metadata) > 0 {
		var meta map[string]any
		if err := json.Unmarshal(e.Metadata, &meta); err == nil {
			de.Metadata = meta
		}
	}
	return de
}

func ToDomainOfferEmailLog(l sqlc.OfferEmailLog) domain.OfferEmailLog {
	dl := domain.OfferEmailLog{
		ID:             l.ID.String(),
		OrganizationID: l.OrganizationID.String(),
		OfferID:        l.OfferID.String(),
		RevisionID:     l.RevisionID.String(),
		ShareLinkID:    l.ShareLinkID.String(),
		Recipient:      l.Recipient,
		Subject:        l.Subject,
		Status:         l.Status,
		ErrorMessage:   l.ErrorMessage,
		SentAt:         l.SentAt.Time,
	}
	if l.SentBy.Valid {
		s := l.SentBy.String()
		dl.SentBy = &s
	}
	return dl
}
