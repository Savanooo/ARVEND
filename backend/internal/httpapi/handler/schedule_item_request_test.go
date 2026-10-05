package handler

import (
	"encoding/json"
	"testing"
)

// Sorumlu alanı üç durumlu: gönderilmedi (eski istemci -> dokunma), null/""
// (kaldır), kimlik (ata). Eski mobil sürümler PUT'ta alanı hiç göndermez;
// "gönderilmedi"yi "kaldır" saymak sahadaki atamaları sessizce silerdi.
func TestScheduleItemRequestAssigneeTriState(t *testing.T) {
	cases := []struct {
		body    string
		set     bool
		value   string
		wantErr bool
	}{
		{`{"name":"A","status":"planned"}`, false, "", false},
		{`{"name":"A","assigned_employee_id":null}`, true, "", false},
		{`{"name":"A","assigned_employee_id":""}`, true, "", false},
		{`{"name":"A","assigned_employee_id":"9b2f6f1e-0000-4000-8000-000000000001"}`, true, "9b2f6f1e-0000-4000-8000-000000000001", false},
		{`{"name":"A","assigned_employee_id":5}`, true, "", true},
	}
	for _, c := range cases {
		var req scheduleItemRequest
		if err := json.Unmarshal([]byte(c.body), &req); err != nil {
			t.Fatalf("%s: %v", c.body, err)
		}
		in, err := req.toInput("u1")
		if (err != nil) != c.wantErr {
			t.Fatalf("%s: err=%v", c.body, err)
		}
		if c.wantErr {
			continue
		}
		if in.AssigneeSet != c.set || in.AssignedEmployeeID != c.value {
			t.Errorf("%s: set=%v value=%q", c.body, in.AssigneeSet, in.AssignedEmployeeID)
		}
	}
}
