"use client";

import { Input } from "@/components/ui/Input";
import { type AttendanceTimes, withTimeChange } from "@/lib/attendance";

// Ekleme formu ve satır düzenleme penceresinin ortak Giriş/Çıkış/Saat
// alanları. Saat, giriş-çıkıştan hesaplanır (mobil ile aynı: düz fark,
// mola düşülmez); kullanıcı saati elle değiştirirse ona dokunulmaz.
export function AttendanceTimeFields({
  value,
  onChange,
  idPrefix,
}: {
  value: AttendanceTimes;
  onChange: (next: AttendanceTimes) => void;
  idPrefix: string;
}) {
  return (
    <>
      <Input
        label="Giriş"
        name={`${idPrefix}_check_in`}
        type="time"
        value={value.check_in}
        onChange={(e) => onChange(withTimeChange(value, { check_in: e.target.value }))}
      />
      <Input
        label="Çıkış"
        name={`${idPrefix}_check_out`}
        type="time"
        value={value.check_out}
        onChange={(e) => onChange(withTimeChange(value, { check_out: e.target.value }))}
      />
      <Input
        label="Saat"
        name={`${idPrefix}_work_hours`}
        inputMode="decimal"
        className="w-20"
        value={value.work_hours}
        onChange={(e) => onChange({ ...value, work_hours: e.target.value, hoursEdited: true })}
      />
    </>
  );
}
