"""Print a TLC counterexample compactly: action name + variables that changed."""
import re, sys
text = open(sys.argv[1]).read()
for m in re.finditer(r'^Error: (Invariant .*|Temporal .*|Action property .*)$', text, re.M):
    print(m.group(1))
states = re.split(r'^State \d+: ', text, flags=re.M)[1:]
prev = {}
for i, block in enumerate(states, 1):
    head, _, body = block.partition('\n')
    action = re.sub(r' line .*', '', head).strip('<>')
    cur = {}
    for part in re.split(r'^/\\ ', body, flags=re.M)[1:]:
        k, _, v = part.partition(' = ')
        cur[k.strip()] = ' '.join(v.split())
    changed = {k: v for k, v in cur.items() if prev.get(k) != v}
    if i == 1:
        keep = ('st', 'exp', 'srvRev', 'token', 'cacheRev')
        changed = {k: v for k, v in cur.items() if k in keep}
    print(f'{i:2}. {action}: ' + '; '.join(f'{k}={v}' for k, v in changed.items()))
    prev = cur
