package domain

import "time"

// ARVEND V2 — Sprint 3: Proje Sözleşmesi (Contract). Bu, projenin GELİR
// (revenue) tarafıdır — Bütçe/Bütçe Revizyonu (Sprint 2, cost-side) İLE
// KARIŞTIRILMAMALI. Durum makinesi:
//
//	draft -> active -> completed   (normal tamamlanma)
//	draft -> cancelled              (yalnızca draft'tan, gerekçe zorunlu)
//	active -> terminated            (yalnızca active'ten, gerekçe zorunlu)
//
// completed/cancelled/terminated ÜÇÜ DE terminal — Sprint 3'te hiçbir
// geri dönüş/yeniden açma YOK. DRAFT bir sözleşme ASLA terminate
// edilemez (hiç yürürlüğe girmemiş bir şey feshedilemez).
//
// contract_amount/currency/source_offer_id/source_revision_id/müşteri
// anlık görüntüsü BURADA YOKTUR — bunlar ZATEN projects tablosunda
// immutable (bkz. UpdateProject'in kendi yorumu), tekrar edilmez.

// ---------- Durum sabitleri ----------

const (
	ContractStatusDraft      = "draft"
	ContractStatusActive     = "active"
	ContractStatusCompleted  = "completed"
	ContractStatusCancelled  = "cancelled"
	ContractStatusTerminated = "terminated"
)

var validContractStatuses = map[string]bool{
	ContractStatusDraft: true, ContractStatusActive: true, ContractStatusCompleted: true,
	ContractStatusCancelled: true, ContractStatusTerminated: true,
}

func ValidContractStatus(s string) bool { return validContractStatuses[s] }

// ---------- Proje olayları (project_events -- mevcut altyapı, YENİ tablo YOK) ----------

const (
	ProjectEventContractCreated      = "contract_created"
	ProjectEventContractUpdated      = "contract_updated"       // draft alan düzenlemesi
	ProjectEventContractNotesUpdated = "contract_notes_updated" // internal_notes düzenlemesi
	ProjectEventContractActivated    = "contract_activated"
	ProjectEventContractCompleted    = "contract_completed"
	ProjectEventContractCancelled    = "contract_cancelled"
	ProjectEventContractTerminated   = "contract_terminated"
)

// ---------- Domain tipi ----------

// ProjectContract, project_contracts satırının domain karşılığıdır.
// Scope/PaymentTerms/RetentionTerms/AdvanceTerms/EffectiveDate/
// PlannedCompletionDate "ticari temel" (baseline) alanlarıdır — ACTIVE
// sonrası servis katmanında düzenlemeye KAPALIDIR (bkz.
// project_contract_service.go). InternalNotes ticari DEĞİLDİR, draft VE
// active'te düzenlenebilir kalır.
type ProjectContract struct {
	ID             string
	OrganizationID string
	ProjectID      string
	Currency       string
	Status         string

	Scope                 string
	PaymentTerms          string
	RetentionTerms        string
	AdvanceTerms          string
	EffectiveDate         *time.Time
	PlannedCompletionDate *time.Time

	InternalNotes string

	CreatedBy *string
	CreatedAt time.Time
	UpdatedAt time.Time

	ActivatedAt *time.Time
	ActivatedBy *string

	CompletedAt *time.Time
	CompletedBy *string

	CancelledAt  *time.Time
	CancelledBy  *string
	CancelReason string

	TerminatedAt      *time.Time
	TerminatedBy      *string
	TerminationReason string
}
