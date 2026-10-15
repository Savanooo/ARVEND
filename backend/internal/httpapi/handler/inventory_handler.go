package handler

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Stok Takibi (migration 0072). İzin kapıları router'da: okuma
// inventory.read; kart, giriş, çıkış, aktarım ve ek inventory.manage; fire,
// sayım, fiş iptali ve depolar inventory.adjust. Birim maliyet ve stok
// değeri yalnızca inventory.manage sahibine döner (Saha para görmez).

type InventoryHandler struct {
	svc *service.InventoryService
}

func NewInventoryHandler(svc *service.InventoryService) *InventoryHandler {
	return &InventoryHandler{svc: svc}
}

func canSeeInventoryValues(r *http.Request) bool {
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	return ok && authz.HasPermission(domain.PermInventoryManage)
}

func dateStr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format(dateLayout)
	return &s
}

func parseOptDate(raw *string) (*time.Time, error) {
	if raw == nil || strings.TrimSpace(*raw) == "" {
		return nil, nil
	}
	t, err := time.Parse(dateLayout, strings.TrimSpace(*raw))
	if err != nil {
		return nil, fmt.Errorf("%w: tarih YYYY-AA-GG biçiminde olmalı (%q)", service.ErrInventoryInvalid, *raw)
	}
	return &t, nil
}

// ---------- Yanıtlar ----------

type inventoryWarehouseResponse struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Address   string `json:"address"`
	Notes     string `json:"notes"`
	IsActive  bool   `json:"is_active"`
	ItemCount int    `json:"item_count"`
	CreatedAt string `json:"created_at"`
}

func toInventoryWarehouseResponse(w service.InventoryWarehouse) inventoryWarehouseResponse {
	return inventoryWarehouseResponse{
		ID: w.ID, Name: w.Name, Address: w.Address, Notes: w.Notes, IsActive: w.IsActive,
		ItemCount: w.ItemCount, CreatedAt: w.CreatedAt.Format(time.RFC3339),
	}
}

type inventoryItemResponse struct {
	ID               string   `json:"id"`
	Code             string   `json:"code"`
	Name             string   `json:"name"`
	Barcode          string   `json:"barcode"`
	Unit             string   `json:"unit"`
	Category         string   `json:"category"`
	ProductID        *string  `json:"product_id"`
	MinStock         *float64 `json:"min_stock"`
	TrackExpiry      bool     `json:"track_expiry"`
	ShelfLifeMonths  *int     `json:"shelf_life_months"`
	ExpiryPolicy     string   `json:"expiry_policy"`
	ExpiryAlertDays  int      `json:"expiry_alert_days"`
	Notes            string   `json:"notes"`
	IsActive         bool     `json:"is_active"`
	Quantity         float64  `json:"quantity"`
	NearestExpiry    *string  `json:"nearest_expiry"`
	ExpiredQuantity  float64  `json:"expired_quantity"`
	ExpiringQuantity float64  `json:"expiring_quantity"`
	BelowMin         bool     `json:"below_min"`
	// Yalnızca inventory.manage sahibine.
	AvgUnitCost *float64 `json:"avg_unit_cost,omitempty"`
	StockValue  *float64 `json:"stock_value,omitempty"`
}

func toInventoryItemResponse(i service.InventoryItem, values bool) inventoryItemResponse {
	out := inventoryItemResponse{
		ID: i.ID, Code: i.Code, Name: i.Name, Barcode: i.Barcode, Unit: i.Unit, Category: i.Category,
		ProductID: nonEmptyPtr(i.ProductID), MinStock: i.MinStock, TrackExpiry: i.TrackExpiry,
		ShelfLifeMonths: i.ShelfLifeMonths, ExpiryPolicy: i.ExpiryPolicy, ExpiryAlertDays: i.ExpiryAlertDays,
		Notes: i.Notes, IsActive: i.IsActive, Quantity: i.Quantity, NearestExpiry: dateStr(i.NearestExpiry),
		ExpiredQuantity: i.ExpiredQuantity, ExpiringQuantity: i.ExpiringQuantity, BelowMin: i.BelowMin(),
	}
	if values {
		avg := i.AvgUnitCost
		value := roundMoney(i.Quantity * i.AvgUnitCost)
		out.AvgUnitCost, out.StockValue = &avg, &value
	}
	return out
}

type inventoryBalanceResponse struct {
	WarehouseID    string  `json:"warehouse_id"`
	WarehouseName  string  `json:"warehouse_name"`
	LotID          *string `json:"lot_id"`
	LotNo          string  `json:"lot_no"`
	ExpiryDate     *string `json:"expiry_date"`
	ProductionDate *string `json:"production_date"`
	Quantity       float64 `json:"quantity"`
}

type inventoryDocumentSummaryResponse struct {
	ID                  string `json:"id"`
	DocNo               string `json:"doc_no"`
	DocType             string `json:"doc_type"`
	DocDate             string `json:"doc_date"`
	Status              string `json:"status"`
	Counterparty        string `json:"counterparty"`
	ReferenceNo         string `json:"reference_no"`
	Reason              string `json:"reason"`
	WarehouseName       string `json:"warehouse_name"`
	TargetWarehouseName string `json:"target_warehouse_name"`
	ProjectName         string `json:"project_name"`
	CreatedByName       string `json:"created_by_name"`
	CreatedAt           string `json:"created_at"`
	ItemCount           int    `json:"item_count"`
	FirstItemName       string `json:"first_item_name"`
	IsReversal          bool   `json:"is_reversal"`
}

func toInventoryDocumentSummaryResponse(d service.InventoryDocumentSummary) inventoryDocumentSummaryResponse {
	return inventoryDocumentSummaryResponse{
		ID: d.ID, DocNo: d.DocNo, DocType: d.DocType, DocDate: d.DocDate.Format(dateLayout), Status: d.Status,
		Counterparty: d.Counterparty, ReferenceNo: d.ReferenceNo, Reason: d.Reason, WarehouseName: d.WarehouseName,
		TargetWarehouseName: d.TargetWarehouseName, ProjectName: d.ProjectName, CreatedByName: d.CreatedByName,
		CreatedAt: d.CreatedAt.Format(time.RFC3339), ItemCount: d.ItemCount, FirstItemName: d.FirstItemName,
		IsReversal: d.IsReversal,
	}
}

type inventoryLineResponse struct {
	LineNo        int      `json:"line_no"`
	ItemID        string   `json:"item_id"`
	ItemCode      string   `json:"item_code"`
	ItemName      string   `json:"item_name"`
	Unit          string   `json:"unit"`
	WarehouseID   string   `json:"warehouse_id"`
	WarehouseName string   `json:"warehouse_name"`
	LotID         *string  `json:"lot_id"`
	LotNo         string   `json:"lot_no"`
	ExpiryDate    *string  `json:"expiry_date"`
	Quantity      float64  `json:"quantity"`
	UnitCost      *float64 `json:"unit_cost,omitempty"`
}

type inventoryDocumentResponse struct {
	inventoryDocumentSummaryResponse
	WarehouseID       string                  `json:"warehouse_id"`
	TargetWarehouseID *string                 `json:"target_warehouse_id"`
	ProjectID         *string                 `json:"project_id"`
	ProjectNo         string                  `json:"project_no"`
	SupplierID        *string                 `json:"supplier_id"`
	SupplierName      string                  `json:"supplier_name"`
	Note              string                  `json:"note"`
	HasAttachment     bool                    `json:"has_attachment"`
	AttachmentName    string                  `json:"attachment_name"`
	AttachmentMime    string                  `json:"attachment_mime"`
	ReversalOfID      *string                 `json:"reversal_of_id"`
	ReversalOfNo      string                  `json:"reversal_of_no"`
	ReversedByDocID   *string                 `json:"reversed_by_doc_id"`
	ReversedByDocNo   string                  `json:"reversed_by_doc_no"`
	ReversedAt        *string                 `json:"reversed_at"`
	ReversedByName    string                  `json:"reversed_by_name"`
	ReverseReason     string                  `json:"reverse_reason"`
	Lines             []inventoryLineResponse `json:"lines"`
	Warnings          []string                `json:"warnings"`
}

func toInventoryDocumentResponse(d *service.InventoryDocument, values bool) inventoryDocumentResponse {
	out := inventoryDocumentResponse{
		inventoryDocumentSummaryResponse: toInventoryDocumentSummaryResponse(d.InventoryDocumentSummary),
		WarehouseID:                      d.WarehouseID, TargetWarehouseID: nonEmptyPtr(d.TargetWarehouseID),
		ProjectID: nonEmptyPtr(d.ProjectID), ProjectNo: d.ProjectNo, SupplierID: nonEmptyPtr(d.SupplierID),
		SupplierName: d.SupplierName, Note: d.Note, HasAttachment: d.AttachmentMime != "",
		AttachmentName: d.AttachmentName, AttachmentMime: d.AttachmentMime,
		ReversalOfID: nonEmptyPtr(d.ReversalOfID), ReversalOfNo: d.ReversalOfNo,
		ReversedByDocID: nonEmptyPtr(d.ReversedByDocID), ReversedByDocNo: d.ReversedByDocNo,
		ReversedAt: tsStrPtr(d.ReversedAt), ReversedByName: d.ReversedByName, ReverseReason: d.ReverseReason,
		Lines: make([]inventoryLineResponse, len(d.Lines)), Warnings: d.Warnings,
	}
	if out.Warnings == nil {
		out.Warnings = []string{}
	}
	for i, l := range d.Lines {
		line := inventoryLineResponse{
			LineNo: l.LineNo, ItemID: l.ItemID, ItemCode: l.ItemCode, ItemName: l.ItemName, Unit: l.Unit,
			WarehouseID: l.WarehouseID, WarehouseName: l.WarehouseName, LotID: nonEmptyPtr(l.LotID), LotNo: l.LotNo,
			ExpiryDate: dateStr(l.ExpiryDate), Quantity: l.Quantity,
		}
		if values {
			c := l.UnitCost
			line.UnitCost = &c
		}
		out.Lines[i] = line
	}
	return out
}

// ---------- Özet ve uyarılar ----------

// Summary: GET /inventory/summary.
func (h *InventoryHandler) Summary(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	sum, err := h.svc.Summary(r.Context(), orgID)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	values := canSeeInventoryValues(r)
	resp := map[string]any{
		"item_count": sum.ItemCount, "expired_lot_count": sum.ExpiredLotCount,
		"expiring_lot_count": sum.ExpiringLotCount, "below_min_count": sum.BelowMinCount,
		"can_see_values": values,
	}
	if values {
		resp["stock_value"] = roundMoney(sum.StockValue)
	}
	httpjson.Write(w, http.StatusOK, resp)
}

// Alerts: GET /inventory/alerts -- SKT'si geçen/yaklaşan partiler.
func (h *InventoryHandler) Alerts(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.LotAlerts(r.Context(), orgID)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	type alert struct {
		ItemID        string  `json:"item_id"`
		ItemCode      string  `json:"item_code"`
		ItemName      string  `json:"item_name"`
		Unit          string  `json:"unit"`
		ExpiryPolicy  string  `json:"expiry_policy"`
		WarehouseID   string  `json:"warehouse_id"`
		WarehouseName string  `json:"warehouse_name"`
		LotID         string  `json:"lot_id"`
		LotNo         string  `json:"lot_no"`
		ExpiryDate    string  `json:"expiry_date"`
		Quantity      float64 `json:"quantity"`
		Expired       bool    `json:"expired"`
	}
	out := make([]alert, len(rows))
	for i, a := range rows {
		out[i] = alert{
			ItemID: a.ItemID, ItemCode: a.ItemCode, ItemName: a.ItemName, Unit: a.Unit, ExpiryPolicy: a.ExpiryPolicy,
			WarehouseID: a.WarehouseID, WarehouseName: a.WarehouseName, LotID: a.LotID, LotNo: a.LotNo,
			ExpiryDate: a.ExpiryDate.Format(dateLayout), Quantity: a.Quantity, Expired: a.Expired,
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"alerts": out})
}

// ---------- Depolar ----------

type inventoryWarehouseRequest struct {
	Name     string `json:"name"`
	Address  string `json:"address"`
	Notes    string `json:"notes"`
	IsActive *bool  `json:"is_active"`
}

// ListWarehouses: GET /inventory/warehouses.
func (h *InventoryHandler) ListWarehouses(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListWarehouses(r.Context(), orgID)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	out := make([]inventoryWarehouseResponse, len(rows))
	for i, wh := range rows {
		out[i] = toInventoryWarehouseResponse(wh)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"warehouses": out})
}

// CreateWarehouse: POST /inventory/warehouses.
func (h *InventoryHandler) CreateWarehouse(w http.ResponseWriter, r *http.Request) {
	var req inventoryWarehouseRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	out, err := h.svc.CreateWarehouse(r.Context(), orgID, service.InventoryWarehouseInput{
		Name: req.Name, Address: req.Address, Notes: req.Notes, UserID: userID,
	})
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toInventoryWarehouseResponse(*out))
}

// UpdateWarehouse: PUT /inventory/warehouses/{id}.
func (h *InventoryHandler) UpdateWarehouse(w http.ResponseWriter, r *http.Request) {
	var req inventoryWarehouseRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	out, err := h.svc.UpdateWarehouse(r.Context(), orgID, chi.URLParam(r, "id"), service.InventoryWarehouseInput{
		Name: req.Name, Address: req.Address, Notes: req.Notes, IsActive: req.IsActive,
	})
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toInventoryWarehouseResponse(*out))
}

// WarehouseBalances: GET /inventory/warehouses/{id}/balances -- sayım ekranı.
func (h *InventoryHandler) WarehouseBalances(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.WarehouseBalances(r.Context(), orgID, chi.URLParam(r, "id"))
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	type balance struct {
		ItemID     string  `json:"item_id"`
		ItemCode   string  `json:"item_code"`
		ItemName   string  `json:"item_name"`
		Unit       string  `json:"unit"`
		LotID      *string `json:"lot_id"`
		LotNo      string  `json:"lot_no"`
		ExpiryDate *string `json:"expiry_date"`
		Quantity   float64 `json:"quantity"`
	}
	out := make([]balance, len(rows))
	for i, b := range rows {
		out[i] = balance{
			ItemID: b.ItemID, ItemCode: b.ItemCode, ItemName: b.ItemName, Unit: b.Unit, LotID: nonEmptyPtr(b.LotID),
			LotNo: b.LotNo, ExpiryDate: dateStr(b.ExpiryDate), Quantity: b.Quantity,
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"balances": out})
}

// ---------- Malzeme kartları ----------

type inventoryItemRequest struct {
	Code            string   `json:"code"`
	Name            string   `json:"name"`
	Barcode         string   `json:"barcode"`
	Unit            string   `json:"unit"`
	Category        string   `json:"category"`
	ProductID       string   `json:"product_id"`
	MinStock        *float64 `json:"min_stock"`
	TrackExpiry     bool     `json:"track_expiry"`
	ShelfLifeMonths *int     `json:"shelf_life_months"`
	ExpiryPolicy    string   `json:"expiry_policy"`
	ExpiryAlertDays *int     `json:"expiry_alert_days"`
	Notes           string   `json:"notes"`
	IsActive        *bool    `json:"is_active"`
}

func (req inventoryItemRequest) toInput(userID string) service.InventoryItemInput {
	return service.InventoryItemInput{
		Code: req.Code, Name: req.Name, Barcode: req.Barcode, Unit: req.Unit, Category: req.Category,
		ProductID: req.ProductID, MinStock: req.MinStock, TrackExpiry: req.TrackExpiry,
		ShelfLifeMonths: req.ShelfLifeMonths, ExpiryPolicy: req.ExpiryPolicy, ExpiryAlertDays: req.ExpiryAlertDays,
		Notes: req.Notes, IsActive: req.IsActive, UserID: userID,
	}
}

// ListItems: GET /inventory/items?warehouse_id=&include_inactive=1.
func (h *InventoryHandler) ListItems(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	q := r.URL.Query()
	includeInactive := q.Get("include_inactive") == "1" || q.Get("include_inactive") == "true"
	rows, err := h.svc.ListItems(r.Context(), orgID, q.Get("warehouse_id"), includeInactive)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	values := canSeeInventoryValues(r)
	out := make([]inventoryItemResponse, len(rows))
	for i, it := range rows {
		out[i] = toInventoryItemResponse(it, values)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"items": out, "can_see_values": values})
}

// GetItem: GET /inventory/items/{id} -- kart, bakiyeler, son fişler.
func (h *InventoryHandler) GetItem(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	d, err := h.svc.GetItem(r.Context(), orgID, chi.URLParam(r, "id"))
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	values := canSeeInventoryValues(r)
	balances := make([]inventoryBalanceResponse, len(d.Balances))
	for i, b := range d.Balances {
		balances[i] = inventoryBalanceResponse{
			WarehouseID: b.WarehouseID, WarehouseName: b.WarehouseName, LotID: nonEmptyPtr(b.LotID), LotNo: b.LotNo,
			ExpiryDate: dateStr(b.ExpiryDate), ProductionDate: dateStr(b.ProductionDate), Quantity: b.Quantity,
		}
	}
	docs := make([]inventoryDocumentSummaryResponse, len(d.Documents))
	for i, doc := range d.Documents {
		docs[i] = toInventoryDocumentSummaryResponse(doc)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"item": toInventoryItemResponse(d.Item, values), "balances": balances, "documents": docs,
		"can_see_values": values,
	})
}

// FindItemByBarcode: GET /inventory/items/by-barcode/{code}.
func (h *InventoryHandler) FindItemByBarcode(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	code, _ := url.PathUnescape(chi.URLParam(r, "code"))
	it, err := h.svc.FindItemByBarcode(r.Context(), orgID, code)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toInventoryItemResponse(*it, canSeeInventoryValues(r)))
}

// CreateItem: POST /inventory/items (kod boşsa STK-NNNN).
func (h *InventoryHandler) CreateItem(w http.ResponseWriter, r *http.Request) {
	var req inventoryItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	it, err := h.svc.CreateItem(r.Context(), orgID, req.toInput(userID))
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toInventoryItemResponse(*it, canSeeInventoryValues(r)))
}

// UpdateItem: PUT /inventory/items/{id}.
func (h *InventoryHandler) UpdateItem(w http.ResponseWriter, r *http.Request) {
	var req inventoryItemRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	it, err := h.svc.UpdateItem(r.Context(), orgID, chi.URLParam(r, "id"), req.toInput(userID))
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toInventoryItemResponse(*it, canSeeInventoryValues(r)))
}

// ---------- Fişler ----------

type inventoryLineRequest struct {
	ItemID          string   `json:"item_id"`
	Quantity        float64  `json:"quantity"`
	CountedQuantity *float64 `json:"counted_quantity"`
	UnitCost        *float64 `json:"unit_cost"`
	LotID           string   `json:"lot_id"`
	LotNo           string   `json:"lot_no"`
	ExpiryDate      *string  `json:"expiry_date"`
	ProductionDate  *string  `json:"production_date"`
}

type inventoryDocumentRequest struct {
	Date              *string                `json:"date"`
	WarehouseID       string                 `json:"warehouse_id"`
	TargetWarehouseID string                 `json:"target_warehouse_id"`
	ProjectID         string                 `json:"project_id"`
	SupplierID        string                 `json:"supplier_id"`
	Counterparty      string                 `json:"counterparty"`
	ReferenceNo       string                 `json:"reference_no"`
	Reason            string                 `json:"reason"`
	Note              string                 `json:"note"`
	IdempotencyKey    string                 `json:"idempotency_key"`
	Lines             []inventoryLineRequest `json:"lines"`
}

func (h *InventoryHandler) postDocument(docType string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req inventoryDocumentRequest
		if err := httpjson.Decode(r, &req); err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
			return
		}
		date, err := parseOptDate(req.Date)
		if err != nil {
			writeInventoryError(w, err)
			return
		}
		orgID, _ := middleware.OrganizationIDFromContext(r.Context())
		userID, _ := middleware.UserIDFromContext(r.Context())
		in := service.InventoryDocumentInput{
			Type: docType, Date: date, WarehouseID: req.WarehouseID, TargetWarehouseID: req.TargetWarehouseID,
			ProjectID: req.ProjectID, SupplierID: req.SupplierID, Counterparty: req.Counterparty,
			ReferenceNo: req.ReferenceNo, Reason: req.Reason, Note: req.Note, IdempotencyKey: req.IdempotencyKey,
			UserID: userID,
		}
		for _, l := range req.Lines {
			expiry, err := parseOptDate(l.ExpiryDate)
			if err != nil {
				writeInventoryError(w, err)
				return
			}
			prod, err := parseOptDate(l.ProductionDate)
			if err != nil {
				writeInventoryError(w, err)
				return
			}
			in.Lines = append(in.Lines, service.InventoryLineInput{
				ItemID: l.ItemID, Quantity: l.Quantity, CountedQuantity: l.CountedQuantity, UnitCost: l.UnitCost,
				LotID: l.LotID, LotNo: l.LotNo, ExpiryDate: expiry, ProductionDate: prod,
			})
		}
		doc, err := h.svc.PostDocument(r.Context(), orgID, in)
		if err != nil {
			writeInventoryError(w, err)
			return
		}
		httpjson.Write(w, http.StatusCreated, toInventoryDocumentResponse(doc, canSeeInventoryValues(r)))
	}
}

// Receipt / Issue / Transfer / Waste / Count: POST /inventory/{receipts,issues,transfers,waste,counts}.
func (h *InventoryHandler) Receipt(w http.ResponseWriter, r *http.Request) {
	h.postDocument(service.InventoryDocReceipt)(w, r)
}
func (h *InventoryHandler) Issue(w http.ResponseWriter, r *http.Request) {
	h.postDocument(service.InventoryDocIssue)(w, r)
}
func (h *InventoryHandler) Transfer(w http.ResponseWriter, r *http.Request) {
	h.postDocument(service.InventoryDocTransfer)(w, r)
}
func (h *InventoryHandler) Waste(w http.ResponseWriter, r *http.Request) {
	h.postDocument(service.InventoryDocWaste)(w, r)
}
func (h *InventoryHandler) Count(w http.ResponseWriter, r *http.Request) {
	h.postDocument(service.InventoryDocCount)(w, r)
}

// ListDocuments: GET /inventory/documents?type=&warehouse_id=&item_id=&project_id=&limit=&offset=.
func (h *InventoryHandler) ListDocuments(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	rows, err := h.svc.ListDocuments(r.Context(), orgID, service.InventoryDocumentFilter{
		Type: q.Get("type"), WarehouseID: q.Get("warehouse_id"), ItemID: q.Get("item_id"),
		ProjectID: q.Get("project_id"), Limit: limit, Offset: offset,
	})
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	out := make([]inventoryDocumentSummaryResponse, len(rows))
	for i, d := range rows {
		out[i] = toInventoryDocumentSummaryResponse(d)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"documents": out})
}

// GetDocument: GET /inventory/documents/{id}.
func (h *InventoryHandler) GetDocument(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	d, err := h.svc.GetDocument(r.Context(), orgID, chi.URLParam(r, "id"))
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toInventoryDocumentResponse(d, canSeeInventoryValues(r)))
}

// ReverseDocument: POST /inventory/documents/{id}/reverse {"reason"}.
func (h *InventoryHandler) ReverseDocument(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Reason string `json:"reason"`
	}
	if err := decodeOptionalBody(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	d, err := h.svc.ReverseDocument(r.Context(), orgID, chi.URLParam(r, "id"), userID, req.Reason)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toInventoryDocumentResponse(d, canSeeInventoryValues(r)))
}

// UploadAttachment: POST /inventory/documents/{id}/attachment (multipart "file").
func (h *InventoryHandler) UploadAttachment(w http.ResponseWriter, r *http.Request) {
	body, name, _, err := readUpload(w, r)
	if err != nil {
		if errors.Is(err, service.ErrFileTooLarge) {
			writeInventoryError(w, err)
			return
		}
		httpjson.Error(w, http.StatusBadRequest, "dosya okunamadı")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	d, err := h.svc.SetAttachment(r.Context(), orgID, chi.URLParam(r, "id"), name, body)
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toInventoryDocumentResponse(d, canSeeInventoryValues(r)))
}

// DownloadAttachment: GET /inventory/documents/{id}/attachment.
func (h *InventoryHandler) DownloadAttachment(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	mime, name, rc, err := h.svc.OpenAttachment(r.Context(), orgID, chi.URLParam(r, "id"))
	if err != nil {
		writeInventoryError(w, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", mime)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`inline; filename*=UTF-8''%s`, url.PathEscape(name)))
	w.Header().Set("Cache-Control", "private, max-age=300")
	_, _ = io.Copy(w, rc)
}

func writeInventoryError(w http.ResponseWriter, err error) {
	var notFound *service.NotFoundError
	switch {
	case errors.As(err, &notFound):
		httpjson.Error(w, http.StatusNotFound, notFound.Error())
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "bulunamadı")
	case errors.Is(err, service.ErrInventoryInvalid),
		errors.Is(err, service.ErrEmptyFile),
		errors.Is(err, service.ErrUnsupportedType):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrFileTooLarge):
		httpjson.Error(w, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, service.ErrInventoryDuplicateCode),
		errors.Is(err, service.ErrInventoryDuplicateBarcode),
		errors.Is(err, service.ErrInventoryDuplicateName),
		errors.Is(err, service.ErrInventoryWarehouseHasStock),
		errors.Is(err, service.ErrInventoryItemHasStock),
		errors.Is(err, service.ErrInventoryInactive),
		errors.Is(err, service.ErrInventoryInsufficient),
		errors.Is(err, service.ErrInventoryExpiredBlocked),
		errors.Is(err, service.ErrInventoryAlreadyReversed),
		errors.Is(err, service.ErrInventoryNotReversible):
		httpjson.Error(w, http.StatusConflict, err.Error())
	default:
		writeInternalError(w, err)
	}
}
