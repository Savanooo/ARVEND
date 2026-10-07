package domain

import "testing"

func TestNormalizePersonName(t *testing.T) {
	same := [][2]string{
		{"Batuhan İnci", "BATUHAN INCI"},
		{"Batuhan İnci", "batuhan inci"},
		{"Batuhan İnci", "Batuhan Inci"},
		{"Batuhan İnci", "  Batuhan   İnci "},
		{"Ahmet Şahin", "AHMET SAHIN"},
		{"Gülşen Öztürk", "gulsen ozturk"},
		{"Çağrı Işık", "CAGRI ISIK"},
		{"İsmail", "i̇smail"}, // "i + birleşik nokta" biçimi
		{"Hâkim Ünal", "Hakim Unal"},
	}
	for _, p := range same {
		if !SamePersonName(p[0], p[1]) {
			t.Errorf("%q ile %q aynı ad sayılmalı (%q / %q)", p[0], p[1], NormalizePersonName(p[0]), NormalizePersonName(p[1]))
		}
	}
	different := [][2]string{
		{"batu", "Batuhan İnci"},
		{"Ali Yılmaz", "Ali Yılmazer"},
		{"Ali Veli", "Veli Ali"},
		{"", ""},
		{"   ", ""},
	}
	for _, p := range different {
		if SamePersonName(p[0], p[1]) {
			t.Errorf("%q ile %q aynı ad SAYILMAMALI", p[0], p[1])
		}
	}
}
