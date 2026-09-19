.PHONY: test layout layout-check

test:
	forge test

# layout/ is read by the chain's dump writer, Tempo's genesis and the explorer's decoder;
# commit it after a contract change.
# AST ids are stripped from the layout, since unrelated edits move them.
STRIP_AST_IDS = python3 -c 'import json,sys;\
d=json.load(sys.stdin);\
import re;\
ids=lambda s: re.sub(r"\)[0-9]+_storage", ")_storage", s);\
strip=lambda o: [strip(v) for v in o] if isinstance(o,list) else ({ids(k):strip(v) for k,v in o.items() if k!="astId"} if isinstance(o,dict) else (ids(o) if isinstance(o,str) else o));\
print(json.dumps(strip(d), indent=2, sort_keys=True))'

layout:
	@mkdir -p layout
	@forge inspect Anchoring storage-layout --json | $(STRIP_AST_IDS) > layout/anchoring.json
	@forge inspect Anchoring abi --json > layout/anchoring.abi.json
	@forge test --match-path 'test/SeedFixture.t.sol' >/dev/null
	@forge inspect Anchoring deployedBytecode > layout/anchoring.bin

layout-check: layout
	@git diff --exit-code -- layout || \
		{ echo "layout/ changed: commit it and update its readers"; exit 1; }
