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
}

// DefaultOrganizationID, mevcut tek-firmalı veri için 0009 migration'ında
// oluşturulan sabit organizasyon kimliğidir (seedAdmin ve tek seferlik
// araçlarda referans için).
const DefaultOrganizationID = "00000000-0000-0000-0000-000000000001"
