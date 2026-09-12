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
			r.Put("/{id}/status", d.Offers.UpdateStatus)
			r.Post("/{id}/toggle-passive", d.Offers.TogglePassive)
			r.Delete("/{id}", d.Offers.Delete)
		})
	})

	return r
}
