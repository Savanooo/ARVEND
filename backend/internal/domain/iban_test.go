package domain

import "testing"

func TestValidIBAN(t *testing.T) {
	cases := []struct {
		raw  string
		want bool
	}{
		{"TR330006100519786457841326", true},
		{"tr33 0006 1005 1978 6457 8413 26", true}, // boşluk ve küçük harf normalize edilir
		{"DE89370400440532013000", true},           // yabancı IBAN (22 hane)
		{"GB82WEST12345698765432", true},           // harfli BBAN
		{"TR330006100519786457841327", false},      // kontrol basamağı tutmuyor
		{"TR12 0006 1234", false},                  // eksik hane
		{"TR3300061005197864578413261", false},     // TR 27 hane
		{"330006100519786457841326TR", false},      // ülke kodu yok
		{"TRAB0006100519786457841326", false},      // kontrol basamağı harf
		{"TR33-0006-1005-1978-6457-8413-26", false},
		{"", false},
	}
	for _, c := range cases {
		if got := ValidIBAN(NormalizeIBAN(c.raw)); got != c.want {
			t.Errorf("ValidIBAN(%q) = %v, beklenen %v", c.raw, got, c.want)
		}
	}
}

func TestNormalizeIBAN(t *testing.T) {
	if got := NormalizeIBAN(" tr33 0006\t1005 1978\n6457 8413 26 "); got != "TR330006100519786457841326" {
		t.Errorf("NormalizeIBAN = %q", got)
	}
}
