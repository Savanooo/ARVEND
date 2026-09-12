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
	JWT         *auth.JWTIssuer
	Auth        *handler.AuthHandler
	Users       *handler.UserHandler
	Products    *handler.ProductHandler
	Offers      *handler.OfferHandler
	Customers   *handler.CustomerHandler
	Employees   *handler.EmployeeHandler
	Attendance  *handler.AttendanceHandler
	Settings    *handler.SettingsHandler
	PublicOffer *handler.PublicOfferHandler
	CORSOrigins []string
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
			r.Delete("/{id}", d.Offers.Delete)
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
	})

	return r
}
