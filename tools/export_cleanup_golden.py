"""Freeze production Python cleanup oracle; no model inference."""
import ast, difflib, hashlib, json, random, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REFERENCE=ROOT/'spikes/python-reference'
sys.path.insert(0,str(REFERENCE))
from stt_service import cleanup as c
rng=random.Random(426019)
pairs=[]
for node in ast.walk(ast.parse((REFERENCE/'tests/test_cleanup.py').read_text())):
    if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id=='drifted':
        try: pairs.append(tuple(ast.literal_eval(x) for x in node.args))
        except (ValueError,TypeError): pass
    if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='cases' for t in node.targets):
        try: pairs.extend(ast.literal_eval(node.value))
        except (ValueError,TypeError): pass
vocab='i you we not no never because if unless build tests fix merge branch today anyways anyway the a so really um uh you know'.split()
for _ in range(600):
    a=[rng.choice(vocab) for _ in range(rng.randrange(90))]; b=a[:]
    for _ in range(rng.randrange(1,6)):
        i=rng.randrange(len(b)+1); b[i:i+rng.randrange(4)]=[rng.choice(vocab) for _ in range(rng.randrange(4))]
    pairs.append((' '.join(a),' '.join(b)))
pairs += [('we '+'the a '*n+'not build','we '+'a the '*n+'build') for n in (5,100,150)]
pairs += [("I'm can't won't shan't let's cannot we'd he's",'I am can not will not shall not let us can not we would he is'),('İ K é 中文 １２３','i k'),("' ' um",'')]
matcher=[]
for autojunk in (False,True):
    examples=[([],[]),(list('tide'),list('diet')),(list('ab'*150),list('ba'*150)),(list('x'+'a'*300),list('y'+'a'*300)),(list('a'*199),list('a'*200))]
    for _ in range(300):
        a=[rng.choice('abcd') for _ in range(rng.randrange(330))]; b=a[:]
        for _ in range(4):
            i=rng.randrange(len(b)+1); b[i:i+rng.randrange(20)]=[rng.choice('abcd') for _ in range(rng.randrange(20))]
        examples.append((a,b))
    for a,b in examples:
        sm=difflib.SequenceMatcher(None,a,b,autojunk=autojunk)
        matcher.append(dict(a=a,b=b,autojunk=autojunk,ratio=sm.ratio(),opcodes=[dict(zip(('tag','i1','i2','j1','j2'),x)) for x in sm.get_opcodes()]))
replacements=[('Faber Lang wrote a cat catalog',[('cat','dog'),('Faber','FABER'),('Faber Lang','FaberLang')]),('é élan aé é_ é2 e\u0301 中文 中文字 Ⅻ ²',[('é','E'),('中文','Chinese'),('Ⅻ','12'),('²','two')]),('cat dog cat!',[('cat','dog'),('dog','wolf')]),('aa ab a',[('aa','ab'),('ab','done'),('','ignored')]),('use em el ex today $1',[('em el ex','MLX'),('$1','\\literal')]),('👩‍💻 programmer',[('👩‍💻','engineer'),('programmer','coder')])]
wrappers=['Sure, here is the cleaned transcript:\n\n"Stop here."','Sure! Here is the cleaned transcript:\nStop here.','Sure, that works for me.',' “hello” ','<transcript>\nhello\n</transcript>','"<transcript>hello</transcript>"','""','  ','\x1chello\x1f','okay\u0301 transcript: hello','sure texté: hello','SURE, here is the tranſcrİpt:\nHello.','sure text: hello\x1c']
chunk_inputs=['','   ','Hello.\x1cNext!','x '*41,' '.join(['one two three four five six seven eight nine ten.']*9),'a!\n\tb? c.']
pair_objects=lambda p:[dict(source=a,replacement=b) for a,b in p]
def accepted(source,response):
    cleaned=c.strip_wrapping(response)
    return cleaned if cleaned and not c.drifted(source,cleaned) else None

data=dict(provenance=dict(source='stt_service/cleanup.py',sha256=hashlib.sha256((REFERENCE/'stt_service/cleanup.py').read_bytes()).hexdigest(),seed=426019),drift=[dict(source=a,cleaned=b,expected=c.drifted(a,b),accepted=accepted(a,b)) for a,b in pairs],matcher=matcher,replacements=[dict(text=t,pairs=pair_objects(p),expected=c.apply_replacements(t,p)) for t,p in replacements],wrappers=[dict(text=t,expected=c.strip_wrapping(t)) for t in wrappers],chunks=[dict(text=t,expected=c.chunks(t)) for t in chunk_inputs],messages=[dict(text=t,pairs=pair_objects(p),expected=c.cleanup_messages(t,p)) for t,p in replacements[:2]])
output=ROOT/'dictate/Tests/DictateCoreTests/Fixtures/cleanup-golden.json'
output.write_text(json.dumps(data,ensure_ascii=False,separators=(',',':'))+'\n')
print(f'{len(pairs)} drift pairs; {len(matcher)} matcher pairs; {output.stat().st_size} bytes')
