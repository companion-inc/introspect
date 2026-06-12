# Frustration Tripwires

The foreground hook and Codex transcript scanner use exact lowercase word matches only. No prefixes, no wildcards, no phrase triggers.

Codex Desktop has a scanner backstop because changed command hooks can be skipped until the hook definition is trusted or the app session reloads config. The scanner reads recent `~/.codex/sessions/**/rollout-*.jsonl` files, ignores Codex control/context records, dedupes transcript lines, and queues missed frustration prompts through the same single-worker cooldown path.

## Active Words

- `arse`
- `ass`
- `asshole`
- `bastard`
- `bitch`
- `bullshit`
- `crap`
- `cunt`
- `damn`
- `dipshit`
- `dumb`
- `dumbass`
- `dumbfuck`
- `fag`
- `faggot`
- `ffs`
- `fuck`
- `fucked`
- `fucker`
- `fuckin`
- `fucking`
- `goddamn`
- `hell`
- `idiot`
- `mf`
- `moron`
- `motherfucker`
- `motherfucking`
- `nigga`
- `nigger`
- `retard`
- `retarded`
- `shitty`
- `stupid`
- `wtf`

## Examples

- `what the fuck is going on` -> triggers on `fuck`
- `why the hell would it do that` -> triggers on `hell`
- `this is bullshit` -> triggers on `bullshit`
- `that behavior is shitty` -> triggers on `shitty`
