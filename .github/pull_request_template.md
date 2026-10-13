## What does this change?

## How was it tested?
- [ ] `./scripts/test.sh` passes
- [ ] `./build.sh` builds
- [ ] Checked the UI with `./build.sh dev` and the snapshot tool (if UI changed)

## Safety checklist
- [ ] No tokens, client IDs, account screenshots or real API responses in the diff
- [ ] Network calls go through `HTTPClient` to the broker's own host only
- [ ] Anything that places orders stays behind the opt-in setting and the confirm step
