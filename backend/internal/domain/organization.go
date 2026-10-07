package domain

import "time"

type OrgStatus string

const (
	OrgStatusActive    OrgStatus = "active"
	OrgStatusTrial     OrgStatus = "trial"
	OrgStatusSuspended OrgStatus = "suspended"
	OrgStatusCancelled OrgStatus = "cancelled"
)

func (s OrgStatus) Valid() bool {
	switch s {
	case OrgStatusActive, OrgStatusTrial, OrgStatusSuspended, OrgStatusCancelled:
		return true
	}
	return false
}

// AllowsAccess, bu durumdaki bir organizasyonun kullanıcılarının API'ye
// erişmeye devam edip edemeyeceğini belirler -- RequireAuth middleware'i
// her istekte bunu kontrol eder (zaten geçerli bir access token'la gelen
// mid-session istekler dahil, bkz. middleware/auth.go).
func (s OrgStatus) AllowsAccess() bool {
	return s == OrgStatusActive || s == OrgStatusTrial
}

// orgStatusTransitions, Süper Admin'in firma yaşam döngüsünde izin verilen
// geçişlerdir. SİLME YOKTUR: cancelled da bir durumdur -- satır ve tüm
// tarihçe (kullanıcılar, teklifler, projeler, finans) olduğu gibi korunur;
// cancelled -> active yeniden aktivasyondur (müşteri geri döndü). trial'a
// geri dönüş yoktur.
var orgStatusTransitions = map[OrgStatus][]OrgStatus{
	OrgStatusTrial:     {OrgStatusActive, OrgStatusSuspended, OrgStatusCancelled},
	OrgStatusActive:    {OrgStatusSuspended, OrgStatusCancelled},
	OrgStatusSuspended: {OrgStatusActive, OrgStatusCancelled},
	OrgStatusCancelled: {OrgStatusActive},
}

func (s OrgStatus) CanTransitionTo(next OrgStatus) bool {
	for _, allowed := range orgStatusTransitions[s] {
		if allowed == next {
			return true
		}
	}
	return false
}

type OnboardingStep string

const (
	OnboardingStepCompany   OnboardingStep = "company"
	OnboardingStepBilling   OnboardingStep = "billing"
	OnboardingStepOffers    OnboardingStep = "offers"
	OnboardingStepFinance   OnboardingStep = "finance"
	OnboardingStepBusiness  OnboardingStep = "business"
	OnboardingStepCompleted OnboardingStep = "completed"
)

// onboardingStepOrder, adımların ileri-yönlü (asla geri gitmeyen) sırasını
// tanımlar -- onboarding_step veri varlığından türetilmez, bu sıradaki
// açık bir işaretçidir (bkz. migration 0030 yorumu).
var onboardingStepOrder = []OnboardingStep{
	OnboardingStepCompany,
	OnboardingStepBilling,
	OnboardingStepOffers,
	OnboardingStepFinance,
	OnboardingStepBusiness,
	OnboardingStepCompleted,
}

func (s OnboardingStep) Valid() bool {
	for _, v := range onboardingStepOrder {
		if v == s {
			return true
		}
	}
	return false
}

// Index, adımın onboardingStepOrder içindeki sırasını döner (geçersizse -1)
// -- OnboardingService'in "asla geriletme" kuralını uygulaması için:
// yalnızca step.Index() >= mevcut_adım.Index() ise ilerletilir.
func (s OnboardingStep) Index() int {
	for i, v := range onboardingStepOrder {
		if v == s {
			return i
		}
	}
	return -1
}

// Next, sıradaki adımı döner; zaten 'completed' ise 'completed' kalır.
func (s OnboardingStep) Next() OnboardingStep {
	for i, v := range onboardingStepOrder {
		if v == s && i+1 < len(onboardingStepOrder) {
			return onboardingStepOrder[i+1]
		}
	}
	return OnboardingStepCompleted
}

type Organization struct {
	ID                    string
	Name                  string
	Slug                  string
	IsActive              bool
	Status                OrgStatus
	PlanCode              string
	TrialEndsAt           *time.Time
	OnboardingCompleted   bool
	OnboardingCompletedAt *time.Time
	OnboardingStep        OnboardingStep
	CreatedAt             time.Time
	UpdatedAt             time.Time
	// DeletedAt/DeletedBy, Status'ten TAMAMEN AYRI bir eksendir (bkz.
	// migration 0043 başlık notu) -- silinen bir firma status'ünü KORUR
	// (ör. "cancelled" iken silinebilir, silindiğinde "cancelled" kalır);
	// erişim engeli status.AllowsAccess() İLE BİRLİKTE, ayrıca kontrol
	// edilir (bkz. AuthService.loadOrgForAccess, middleware/auth.go).
	DeletedAt *time.Time
	DeletedBy *string
}

func (o Organization) IsDeleted() bool { return o.DeletedAt != nil }

// TrialStatus, deneme sürümündeki bir firmanın bitiş durumudur. Ürün kararı
// (2026-10-07): süre dolunca erişim OTOMATİK KESİLMEZ -- bu bilgi yalnızca
// gösterilir (mobil Ana Sayfa bandı; Süper Admin rozeti sonra). Kesmek
// Süper Admin'in SetStatus ile verdiği bilinçli bir karardır.
type TrialStatus struct {
	EndsAt time.Time
	// EndsOn: bitişin İstanbul takvim günü (UTC gece yarısı olarak).
	EndsOn time.Time
	// DaysLeft: EndsOn - bugün (İstanbul günü). Bitiş günü 0 ("bugün
	// bitiyor"), geçtiyse negatif.
	DaysLeft int
	// Expired: bitiş günü geride kaldı. Gün bazlıdır -- bitiş günü boyunca
	// deneme sürmüş sayılır, saatine bakılmaz (kullanıcıya gösterilen de
	// yalnızca tarih).
	Expired bool
}

// Trial, firma deneme sürümündeyse ve bitiş tarihi kayıtlıysa deneme
// durumunu now anına göre loc takviminde (İstanbul) hesaplar; aksi halde
// nil. trial_ends_at oluşturma anında yazılır (PlatformService) ve başka
// hiçbir yerde okunmuyordu -- süresi dolan deneme sessizce tam erişimle
// devam ediyordu.
func (o Organization) Trial(now time.Time, loc *time.Location) *TrialStatus {
	if o.Status != OrgStatusTrial || o.TrialEndsAt == nil {
		return nil
	}
	ey, em, ed := o.TrialEndsAt.In(loc).Date()
	ty, tm, td := now.In(loc).Date()
	endsOn := time.Date(ey, em, ed, 0, 0, 0, 0, time.UTC)
	today := time.Date(ty, tm, td, 0, 0, 0, 0, time.UTC)
	days := int(endsOn.Sub(today).Hours() / 24)
	return &TrialStatus{EndsAt: *o.TrialEndsAt, EndsOn: endsOn, DaysLeft: days, Expired: days < 0}
}

// DefaultOrganizationID, mevcut tek-firmalı veri için 0009 migration'ında
// oluşturulan sabit organizasyon kimliğidir (seedAdmin ve tek seferlik
// araçlarda referans için).
const DefaultOrganizationID = "00000000-0000-0000-0000-000000000001"
