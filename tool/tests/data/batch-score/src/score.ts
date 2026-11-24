export function fuzzyScore(text: string, query: string): number {
  return text.indexOf(query);
}

export function shout(s: string, times: number): string {
  return s.toUpperCase().repeat(times);
}

export function flag(n: number): boolean {
  return n > 0;
}

export function log(s: string): void {
  console.log(s);
}
