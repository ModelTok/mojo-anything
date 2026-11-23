# App replay

Build: `false`

Passed: 0/7

Fallback rate: not reported by this build

## Failing cases

### example-001-upper

Arguments: `upper hello world`

status:

```diff
expected exit code 0, got exit code 1
```

stdout:

```diff
- HELLO WORLD
```

### example-002-len

Arguments: `len héllo`

status:

```diff
expected exit code 0, got exit code 1
```

stdout:

```diff
- 5
```

### example-003-div

Arguments: `div 7 2`

status:

```diff
expected exit code 0, got exit code 1
```

stdout:

```diff
- 7 / 2 = 3 remainder 1
```

### example-004-words

Arguments: `words`

status:

```diff
expected exit code 0, got exit code 1
```

stdout:

```diff
- 3
```

### example-005-copy

Arguments: `copy input.txt out.txt`

status:

```diff
expected exit code 0, got exit code 1
```

stdout:

```diff
- copied 40 characters
```

file out.txt:

```diff
not written
```

### example-006-now

Arguments: `now`

status:

```diff
expected exit code 0, got exit code 1
```

stdout:

```diff
- now: [..]
```

### example-007-nope

Arguments: `nope`

stderr:

```diff
- usage: tcli upper|len|div|words|copy|now
```
