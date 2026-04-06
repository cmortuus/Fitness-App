export function localDateString(date: Date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function parseLocalDateString(isoDate: string): Date {
  const [year, month, day] = isoDate.split('-').map(Number);
  return new Date(year, month - 1, day);
}

export function shiftLocalDateString(isoDate: string, deltaDays: number): string {
  const date = parseLocalDateString(isoDate);
  date.setDate(date.getDate() + deltaDays);
  return localDateString(date);
}

export function daysAgoLocalDateString(daysAgo: number): string {
  const date = new Date();
  date.setDate(date.getDate() - daysAgo);
  return localDateString(date);
}
