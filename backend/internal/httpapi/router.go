// Package httpapi, HTTP router'ı kurar.
package httpapi

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/handler"
	appmw "github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
)

type Deps struct {
	JWT               *auth.JWTIssuer
	Auth              *handler.AuthHandler
	Users             *handler.UserHandler
	Products          *handler.ProductHandler
	Offers            *handler.OfferHandler
	Projects          *handler.ProjectHandler
	Customers         *handler.CustomerHandler
	Employees         *handler.EmployeeHandler
	Attendance        *handler.AttendanceHandler
	Settings          *handler.SettingsHandler
	PublicOffer       *handler.PublicOfferHandler
	PublicChangeOrder *handler.PublicChangeOrderHandler
	CORSOrigins       []string
}

func NewRouter(d Deps) http.Handler {
	r := chi.NewRouter()
	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Logger)
	r.Use(chimw.Recoverer)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   d.CORSOrigins,
		AllowedMethods:   []string{"GET", "POST", "PUT", "PATCH", "DELETE"},
		AllowedHeaders:   []string{"Content-Type"},
		AllowCredentials: true, // httpOnly cookie'lerin cross-origin (frontend :3000 -> backend :8080) taşınabilmesi için
	}))

	requireAuth := appmw.RequireAuth(d.JWT)
	requireAdmin := appmw.RequireRole(domain.RoleAdmin)

	r.Route("/api/v1", func(r chi.Router) {
		r.Route("/auth", func(r chi.Router) {
			r.Post("/login", d.Auth.Login)
			r.Post("/refresh", d.Auth.Refresh)
			r.Post("/logout", d.Auth.Logout)
			r.With(requireAuth).Get("/me", d.Auth.Me)
		})

		r.Route("/users", func(r chi.Router) {
			r.Use(requireAuth)
			r.Patch("/me/password", d.Users.ChangeOwnPassword)

			r.Group(func(r chi.Router) {
				r.Use(requireAdmin)
				r.Get("/", d.Users.List)
				r.Post("/", d.Users.Create)
				r.Get("/{id}", d.Users.Get)
				r.Put("/{id}", d.Users.Update)
				r.Patch("/{id}/password", d.Users.AdminResetPassword)
				r.Delete("/{id}", d.Users.Deactivate)
			})
		})

		r.Route("/products", func(r chi.Router) {
			r.Use(requireAuth)
			// Katalog herkes icin okunabilir (teklif olustururken herkes
			// urun secebilmeli); yazma admin'e ozel.
			r.Get("/", d.Products.List)
			r.Get("/{id}", d.Products.Get)
			r.Get("/{id}/price-history", d.Products.PriceHistory)

			r.Group(func(r chi.Router) {
				r.Use(requireAdmin)
				r.Post("/", d.Products.Create)
				r.Put("/{id}", d.Products.Update)
				r.Delete("/{id}", d.Products.Delete)
			})
		})

		r.Route("/offers", func(r chi.Router) {
			r.Use(requireAuth)
			// Teklif oluşturma/görme gerçek işte sıradan personel işidir --
			// Users/Products'ın aksine admin şartı YOK.
			r.Get("/", d.Offers.List)
			r.Post("/", d.Offers.Create)
			r.Get("/{id}", d.Offers.Get)
			r.Put("/{id}", d.Offers.Update)
			r.Post("/{id}/revise", d.Offers.Revise)
			r.Get("/{id}/revisions", d.Offers.ListRevisions)
			r.Get("/{id}/revisions/{revisionId}", d.Offers.GetRevision)
			r.Put("/{id}/status", d.Offers.UpdateStatus)
			r.Post("/{id}/toggle-passive", d.Offers.TogglePassive)
			r.Post("/{id}/send-email", d.Offers.SendEmail)
			r.Post("/{id}/share-links", d.Offers.CreateShareLink)
			r.Get("/{id}/share-links", d.Offers.ListShareLinks)
			r.Delete("/{id}/share-links/{linkId}", d.Offers.RevokeShareLink)
			r.Get("/{id}/events", d.Offers.ListEvents)
			r.Get("/{id}/email-logs", d.Offers.ListEmailLogs)
			// Teklifin projeye dönüşüp dönüşmediği (dönüşmediyse 404) --
			// teklif detayındaki "Projeye Dönüştür"/"Projeyi Görüntüle"
			// ayrımı buna bakar.
			r.Get("/{id}/project", d.Projects.GetByOffer)
			r.Delete("/{id}", d.Offers.Delete)
		})

		r.Route("/projects", func(r chi.Router) {
			r.Use(requireAuth)
			// Projeler de teklifler gibi sıradan personel işidir -- admin
			// şartı YOK (ileride project.* izinleriyle inceltilecek).
			r.Get("/", d.Projects.List)
			r.Post("/from-offer/{offerId}", d.Projects.CreateFromOffer)
			r.Get("/{id}", d.Projects.Get)
			r.Put("/{id}", d.Projects.Update)
			r.Get("/{id}/financial-summary", d.Projects.FinancialSummary)
			r.Get("/{id}/events", d.Projects.ListEvents)

			r.Get("/{id}/payment-plan", d.Projects.ListPaymentPlan)
			r.Post("/{id}/payment-plan", d.Projects.CreatePaymentPlanItem)
			r.Put("/{id}/payment-plan/{itemId}", d.Projects.UpdatePaymentPlanItem)
			r.Delete("/{id}/payment-plan/{itemId}", d.Projects.CancelPaymentPlanItem)

			r.Get("/{id}/collections", d.Projects.ListCollections)
			r.Post("/{id}/collections", d.Projects.CreateCollection)
			r.Post("/{id}/collections/{collectionId}/void", d.Projects.VoidCollection)

			r.Get("/{id}/expenses", d.Projects.ListExpenses)
			r.Post("/{id}/expenses", d.Projects.CreateExpense)
			r.Put("/{id}/expenses/{expenseId}", d.Projects.UpdateExpense)
			r.Post("/{id}/expenses/{expenseId}/void", d.Projects.VoidExpense)

			r.Get("/{id}/invoices", d.Projects.ListInvoices)
			r.Post("/{id}/invoices", d.Projects.CreateInvoice)
			r.Put("/{id}/invoices/{invoiceId}/status", d.Projects.UpdateInvoiceStatus)

			r.Get("/{id}/subcontractors", d.Projects.ListSubcontractors)
			r.Post("/{id}/subcontractors", d.Projects.CreateSubcontractor)
			r.Put("/{id}/subcontractors/{subcontractorId}", d.Projects.UpdateSubcontractor)
			r.Post("/{id}/subcontractors/{subcontractorId}/payments", d.Projects.CreateSubcontractorPayment)
			r.Get("/{id}/subcontractor-payments", d.Projects.ListSubcontractorPayments)
			r.Post("/{id}/subcontractor-payments/{paymentId}/void", d.Projects.VoidSubcontractorPayment)

			// --- Faz 7: operasyon ---
			r.Get("/{id}/operations-summary", d.Projects.OperationsSummary)

			r.Get("/{id}/members", d.Projects.ListMembers)
			r.Post("/{id}/members", d.Projects.AssignMember)
			r.Delete("/{id}/members/{memberId}", d.Projects.EndMembership)

			r.Get("/{id}/schedule", d.Projects.ListScheduleItems)
			r.Post("/{id}/schedule", d.Projects.CreateScheduleItem)
			r.Put("/{id}/schedule/{itemId}", d.Projects.UpdateScheduleItem)

			r.Get("/{id}/tasks", d.Projects.ListTasks)
			r.Post("/{id}/tasks", d.Projects.CreateTask)
			r.Put("/{id}/tasks/{taskId}", d.Projects.UpdateTask)
			r.Post("/{id}/tasks/{taskId}/complete", d.Projects.CompleteTask)

			r.Get("/{id}/files", d.Projects.ListFiles)
			r.Post("/{id}/files", d.Projects.UploadFile)
			r.Get("/{id}/files/{fileId}/download", d.Projects.DownloadFile)
			r.Delete("/{id}/files/{fileId}", d.Projects.DeleteFile)

			r.Get("/{id}/photos", d.Projects.ListPhotos)
			r.Post("/{id}/photos", d.Projects.UploadPhoto)
			r.Get("/{id}/photos/{photoId}/content", d.Projects.DownloadPhoto)
			r.Delete("/{id}/photos/{photoId}", d.Projects.DeletePhoto)

			r.Get("/{id}/notes", d.Projects.ListNotes)
			r.Post("/{id}/notes", d.Projects.CreateNote)

			// --- Faz 8: ek işler / değişiklik emirleri ---
			r.Get("/{id}/change-orders", d.Projects.ListChangeOrders)
			r.Post("/{id}/change-orders", d.Projects.CreateChangeOrder)
			r.Get("/{id}/change-orders/{changeOrderId}", d.Projects.GetChangeOrder)
			r.Put("/{id}/change-orders/{changeOrderId}", d.Projects.UpdateChangeOrder)
			r.Post("/{id}/change-orders/{changeOrderId}/send", d.Projects.SendChangeOrder)
			r.Post("/{id}/change-orders/{changeOrderId}/send-email", d.Projects.SendChangeOrderEmail)
			r.Post("/{id}/change-orders/{changeOrderId}/revise", d.Projects.ReviseChangeOrder)
			r.Post("/{id}/change-orders/{changeOrderId}/cancel", d.Projects.CancelChangeOrder)
		})

		r.Route("/customers", func(r chi.Router) {
			r.Use(requireAuth)
			// Teklif oluşturan herkes müşteri seçebilmeli/ekleyebilmeli --
			// Ürünler'in aksine (kontrollü katalog), müşteri kartı canlı bir
			// CRM listesi gibi, admin şartı YOK.
			r.Get("/", d.Customers.List)
			r.Post("/", d.Customers.Create)
			r.Get("/{id}", d.Customers.Get)
			r.Put("/{id}", d.Customers.Update)
			r.Delete("/{id}", d.Customers.Archive)
		})

		r.Route("/employees", func(r chi.Router) {
			r.Use(requireAuth)
			// Personel listesi mesai girişinde herkese lazım; hassas
			// yönetim (ekleme/düzenleme/pasifleştirme) admin'e özel.
			r.Get("/", d.Employees.List)
			r.Get("/{id}", d.Employees.Get)

			r.Group(func(r chi.Router) {
				r.Use(requireAdmin)
				r.Post("/", d.Employees.Create)
				r.Put("/{id}", d.Employees.Update)
				r.Delete("/{id}", d.Employees.Archive)
			})
		})

		r.Route("/attendance", func(r chi.Router) {
			r.Use(requireAuth)
			// Mesai girişi BYZ'de sıradan iş -- admin şartı YOK.
			r.Get("/", d.Attendance.ListByMonth)
			r.Post("/", d.Attendance.Create)
			r.Put("/{id}", d.Attendance.Update)
			r.Delete("/{id}", d.Attendance.Delete)
		})

		r.Route("/settings", func(r chi.Router) {
			r.Use(requireAuth, requireAdmin)
			r.Get("/smtp", d.Settings.GetSmtp)
			r.Put("/smtp", d.Settings.UpdateSmtp)
			r.Post("/smtp/test", d.Settings.TestSmtp)
		})

		// Müşterinin auth gerektirmeden erişebildiği paylaşım linki --
		// güvenlik sınırı tahmin edilemez uuid token'ın kendisidir.
		r.Route("/public/offers/{token}", func(r chi.Router) {
			r.Get("/", d.PublicOffer.Get)
			r.Post("/respond", d.PublicOffer.Respond)
		})

		// Faz 8: müşterinin ek işi (değişiklik emri) görüntüleyip kabul/
		// red edebildiği paylaşım linki -- aynı güvenlik sınırı (token).
		r.Route("/public/change-orders/{token}", func(r chi.Router) {
			r.Get("/", d.PublicChangeOrder.Get)
			r.Post("/respond", d.PublicChangeOrder.Respond)
		})
	})

	return r
}
