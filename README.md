# s32

Fantasy console a 16-bit (bus a 24-bit flat, CPU/PPU/APU custom),
motore interamente in LuaJIT.

Ripartenza da zero rispetto al precedente motore Python/Cython dello
stesso progetto — vedi [`docs/design.md`](docs/design.md) per tutte le
decisioni di design e il perché di ciascuna.

## Struttura

- `/` — il motore della console (CPU, PPU, APU, OS, editor)
- `cart/` — cartucce finite, solo gioco
- `dev/` — cartucce in lavorazione
- `docs/` — documentazione
- `tests/` — test automatici e script di supporto

## Stato

Repository appena creato, in fase di prima implementazione. Vedi
`docs/design.md` per il piano completo.
