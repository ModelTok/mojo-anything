// Floats a wasm port must carry exactly (tests/mojo_wasm.rs).

export function third(): number {
  return 0.1 + 0.2
}

export function negZero(): number {
  return -0
}

export function tiny(): number {
  return 5e-324
}

export function huge(): number {
  return 1.7976931348623157e308
}

export function sum(a: number, b: number): number {
  return a + b
}

export function echoAll(xs: number[]): number[] {
  return xs
}

export function same(text: string): string {
  return text
}
