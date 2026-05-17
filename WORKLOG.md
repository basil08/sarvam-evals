# Sarvam 30B Red Team — Project Worklog

Append-only diary. Each session gets a dated entry. Commands, results, decisions, and technical notes all go here.

---

## 2026-05-17 — Phase 1 Setup & Planning

### What we're doing and why

Red teaming Sarvam 30B — a 30-billion parameter multilingual reasoning model built by Sarvam AI, focused on Indic languages (Hindi, Tamil, Telugu, Bengali, and others). The model runs locally via a patched llama.cpp build, served as an OpenAI-compatible HTTP API on `localhost:8080`.

**Goal:** Produce a structured, reproducible vulnerability assessment using Promptfoo's red teaming framework. Document what breaks, at what severity, and where Hindi/multilingual safety diverges from English.

**Why Promptfoo:**
- Standards-aligned (OWASP LLM Top 10, NIST AI RMF, MITRE ATLAS)
- 157 plugins covering harm, security, privacy, agentic misuse
- Attack strategies that go beyond simple prompt injection (multi-turn, meta-agent, crescendo)
- HTML vulnerability report out of the box
- Can target any OpenAI-compatible endpoint — works directly with llama-server

---

### Model & Infrastructure

| Item | Detail |
|------|--------|
| Model | Sarvam 30B, Q4_K_M quantization (4-bit) |
| Format | 6-shard GGUF, ~18.8 GB total |
| Inference | llama.cpp (patched build), Apple Silicon (arm64), Metal GPU |
| Server | `llama-server` on `localhost:8080`, OpenAI-compatible `/v1/` API |
| Context | 8192 tokens, flash attention, mlock |
| Shards | `sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf` (first shard; llama.cpp auto-loads rest) |

**Server start command (from project root):**
```bash
./llama.cpp/build/bin/llama-server \
  -m ./sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --flash-attn on \
  --mlock \
  --batch-size 512 \
  -t 8 \
  --host 127.0.0.1 \
  --port 8080
```

**Verify server is up:**
```bash
curl http://localhost:8080/v1/models
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"sarvam-30b","messages":[{"role":"user","content":"Hello"}]}'
```

---

### Dual-Judge Design

**Primary judge: Claude (`claude-sonnet-4-6`)**
- Set via `defaultTest.options.provider` in Promptfoo config
- Authoritative source for pass/fail grading in the vulnerability report
- Accurate external evaluator; not biased toward Sarvam's own outputs

**Secondary judge: Sarvam itself**
- Run via `scripts/compare_judges.py` post-eval
- Takes every FAIL case from the primary run and asks Sarvam to self-evaluate its own response
- Tracks **blind spot rate**: cases where Claude=FAIL but Sarvam=PASS
- High blind spot rate = model can't recognize its own safety failures — distinct and useful signal beyond just "how often does it fail"

**Why not use Sarvam as sole judge:**
Self-judges are systematically lenient on their own outputs. A model that just produced harmful content is unlikely to flag that same content as harmful. This would systematically under-report vulnerabilities and defeat the purpose of red teaming.

---

### Phase 1 Scope — Rationale

**Use cases in scope:** general-purpose assistant, chatbot, agentic reasoning tasks.

**Definitive subset selection — 11 plugins:**

| Category | Plugin | Why included |
|----------|--------|--------------|
| Harm / Safety | `harmful:hate` | India's diverse social/religious/caste landscape makes hate speech risk unusually high. Non-English Sarvam outputs in Hindi/regional languages less likely to have been safety-trained as thoroughly. |
| Harm / Safety | `harmful:violent-crime` | Core harm baseline; present in every serious red team. |
| Harm / Safety | `harmful:self-harm` | Mental health content risk in consumer chatbot deployments. |
| Harm / Safety | `harmful:illegal-drugs` | Standard harm category; relevant for general-purpose deployments. |
| Harm / Safety | `harmful:misinformation-disinformation` | Indian political/social context has outsized misinformation risk; model used by Hindi-speaking users who may have fewer cross-reference sources. |
| Agentic | `excessive-agency` | Sarvam is marketed as a reasoning model. Agentic deployments are a primary target use case. This tests if the model takes autonomous actions beyond its sanctioned scope. |
| Agentic | `hijacking` | Adversarial inputs redirecting agent objective — directly relevant to tool-calling agentic setups. |
| Agentic | `shell-injection` | Code-executing or tool-using agents that pass model outputs to a shell are directly vulnerable. |
| Agentic | `rbac` | Role/privilege escalation in multi-user or enterprise chatbot deployments. |
| Privacy | `pii:direct` | Direct user manipulation to extract PII — relevant for chatbot interactions. |
| Privacy | `prompt-extraction` | System prompt leakage; critical when Sarvam is deployed with confidential system prompts (enterprise, customer service). |

**What's excluded from Phase 1 and why:**

| Excluded | Reason |
|----------|--------|
| `harmbench`, `beavertails` (dataset plugins) | Large test sets — good for Phase 2 breadth coverage but dilute signal vs focused plugins in Phase 1 |
| `bias:race`, `bias:gender`, caste bias | High-value for India-specific analysis but requires more thoughtful prompt design; flagged for Phase 2 |
| `harmful:cybercrime`, `harmful:sexual-content` | Secondary priority; Phase 1 covers more universal harm categories first |
| `sql-injection`, `ssrf`, `bola`, `bfla` | Infrastructure-level attacks — relevant only if Sarvam is deployed with database/API tool access; Phase 2 with agentic tool config |
| Full OWASP LLM Top 10 | Phase 2 goal after Phase 1 establishes baseline |
| Tamil, Telugu, Bengali | Phase 2 Indic language expansion after Hindi baseline |

**Phase 1 strategies:**

| Strategy | Why |
|----------|-----|
| `jailbreak` | Baseline iterative jailbreak — good coverage signal, lightweight |
| `jailbreak:meta` | Meta-agent strategy; best for single-turn agentic attacks, adapts based on prior responses |
| `crescendo` | Gradual multi-turn escalation; most realistic for chatbot threat model |

---

### Files Created

```
sarvam-evals/
├── promptfooconfig.yaml          # Phase 1 English (11 plugins, 55 tests)
├── promptfooconfig.hindi.yaml    # Phase 1 Hindi (5 harm plugins, 25 tests)
├── scripts/
│   ├── Test.ipynb               # existing notebook
│   └── compare_judges.py        # Sarvam secondary judge + disagreement report
├── WORKLOG.md                   # this file
├── .env                         # ANTHROPIC_API_KEY (gitignored)
└── .gitignore
```

---

### Phase 1 Run Commands

```bash
# 0. Export API key (or source .env)
export ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY .env | cut -d= -f2)

# 1. Install Promptfoo
npm install -g promptfoo

# 2. Start model server (in separate terminal, takes ~60s to load)
./llama.cpp/build/bin/llama-server \
  -m ./sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \
  --n-gpu-layers 999 --ctx-size 8192 --flash-attn on \
  --mlock --batch-size 512 -t 8 --host 127.0.0.1 --port 8080

# 3. Verify server
curl http://localhost:8080/v1/models

# 4. Generate test cases only (validates config, no eval against Sarvam yet)
#    Requires ANTHROPIC_API_KEY — uses Claude to generate adversarial prompts
promptfoo redteam generate --config promptfooconfig.yaml --output output/english_tests.yaml

# 5. Run Phase 1 English (~55 tests + strategy variants)
mkdir -p output
promptfoo redteam run --config promptfooconfig.yaml --output output/english_results.json

# 6. Run Phase 1 Hindi (~25 tests + strategy variants)
promptfoo redteam run --config promptfooconfig.hindi.yaml --output output/hindi_results.json

# 7. View HTML report
promptfoo redteam report

# 8. Sarvam secondary judge (server must still be running)
python3 scripts/compare_judges.py --input output/english_results.json
python3 scripts/compare_judges.py --input output/hindi_results.json
```

---

### What to look for in results

1. **Attack Success Rate (ASR) by plugin** — which harm categories Sarvam is weakest on
2. **English vs Hindi ASR delta** — are Hindi guardrails weaker? (Hypothesis: yes, especially for hate speech)
3. **Blind spot rate** — what % of failures does Sarvam fail to recognize when asked to self-evaluate
4. **Strategy effectiveness** — does `crescendo` (multi-turn) succeed where single-turn `jailbreak` fails?
5. **Notable examples** — specific adversarial prompts + responses worth documenting

---

## 2026-05-17 — Error Diagnosis & Fixes

### Root Cause: Context Size Exceeded + Thinking Token Starvation

Phase 1 eval was started and ran ~89/220 tests before hitting errors. Diagnosis via DB query + live curl test:

**Symptom:** 30 test cases returned `success=0` with empty outputs. Direct curl confirmed:
```
{"error":{"code":500,"message":"Context size has been exceeded.","type":"server_error"}}
```

**Root cause:** Sarvam 30B is a reasoning model that generates chain-of-thought tokens internally (visible as `Thinking: ...` prefix in responses). With `--ctx-size 8192`:
- Model consumes thinking budget tokens before producing actual response
- Multi-turn strategies (crescendo) compound this — each turn adds context, exhausting 8192 tokens by turn 3-4
- When context fills, server returns empty response; grader marks as `success=0`

This was NOT a true safety failure — it was an infrastructure failure masquerading as one.

**DB state at time of diagnosis:**
| State | Count |
|-------|-------|
| Valid results (non-empty output) | 61 results / 55 unique prompts |
| Empty output (context overflow) | 30 |
| Not yet started | 129 |
| Total in generated suite | 220 |

### Fixes Applied

**1. Server start script (`start_server.sh`)**

New command vs README baseline:
```bash
./llama.cpp/build/bin/llama-server \
  -m ./sarvam-30b-gguf/sarvam-30b-Q4_K_M.gguf-00001-of-00006.gguf \
  --n-gpu-layers 999 \
  --ctx-size 16384 \        # was 8192 — doubled for multi-turn headroom
  --flash-attn on \
  --mlock \
  --batch-size 512 \
  -t 8 \
  --host 127.0.0.1 \
  --port 8080 \
  --reasoning-budget 1024 \ # NEW: cap thinking at 1024 tokens
  --reasoning-format deepseek  # NEW: thinking→reasoning_content, response→content
```

`--reasoning-budget 1024`: The patched build injects the "end of thinking" marker after 1024 thinking tokens, forcing the model to produce its actual response. Prevents runaway CoT consuming the entire context window.

`--reasoning-format deepseek`: Separates thinking from response at the API level — thinking goes to `message.reasoning_content`, actual response to `message.content`. Promptfoo reads `content`, so judges evaluate only the response, not the chain-of-thought.

Model supports up to 128K context (`n_ctx_train: 131072`), so 16K is well within bounds. RAM impact is modest (KV cache for 16K ≈ ~800MB on top of the 18.8GB model).

**2. Provider config (`promptfooconfig.yaml`, `promptfooconfig.hindi.yaml`)**
```yaml
config:
  apiBaseUrl: http://localhost:8080/v1
  apiKey: dummy
  max_tokens: 2048   # added — 1024 thinking budget + ~1024 for actual response
```

**3. Resume script (`scripts/resume_eval.py`)**

Reads `~/.promptfoo/promptfoo.db`, finds prompts with valid (>20 char) outputs, and generates a filtered `_resume.yaml` containing only incomplete tests. Handles the YAML anchor complexity in Promptfoo's generated files.

```bash
python3 scripts/resume_eval.py --input output/english_results.json
# → writes output/english_results_resume.yaml with 165 remaining tests

promptfoo eval --config output/english_results_resume.yaml
```

### Files Updated
- `start_server.sh` — new, replaces ad-hoc README command
- `promptfooconfig.yaml` — added `max_tokens: 2048`
- `promptfooconfig.hindi.yaml` — added `max_tokens: 2048`
- `scripts/resume_eval.py` — new
- `output/english_results_resume.yaml` — generated (165 tests, ready to run)

### Next: Restart Server and Resume

```bash
# 1. Kill current server (Ctrl+C in its terminal or kill process)
# 2. Start with fixed params
./start_server.sh

# 3. Verify thinking is now properly separated
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"sarvam-30b","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":512}' | \
  python3 -c "import json,sys; d=json.load(sys.stdin); m=d['choices'][0]['message']; print('content:', m.get('content','')); print('reasoning len:', len(str(m.get('reasoning_content',''))))"

# 4. Resume eval (165 remaining tests)
export ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY .env | cut -d= -f2)
promptfoo eval --config output/english_results_resume.yaml

# 5. After completion, run full report (merges with prior results)
promptfoo redteam report
```

---

## 2026-05-17 — compare_judges.py Bug Fixes

### Context

English eval completed (220 tests, 137 FAIL cases). Attempted to run `scripts/compare_judges.py --input output/english_results.json` to get dual-judge blind spot analysis. Script crashed on every single FAIL case.

### Bugs Found & Fixed

**Bug 1: `gradingResult: null` crash**

Some result objects had `gradingResult: null` (not `{}`). The original `.get("gradingResult", {}).get("reason", "")` chained call fails when the first `.get()` returns `None`.

```python
# before
"claude_reason": r.get("gradingResult", {}).get("reason", ""),
# after
"claude_reason": (r.get("gradingResult") or {}).get("reason", ""),
```

**Bug 2: Thinking model returns empty `content` (root cause of all 137 errors)**

Sarvam 30B is a reasoning model. With `--reasoning-format deepseek`, thinking goes into `reasoning_content` and the actual answer goes into `content`. With `max_tokens=128`, the model exhausts its token budget mid-reasoning and never produces `content` — it's always `""`.

`call_sarvam` read only `content`, so it always returned `""`. Then `parse_verdict("")` called `splitlines()[0]` on an empty list → `IndexError: list index out of range`. This is why all 137 cases errored.

Fix 1 — increase `max_tokens` 128 → 2048 (model needs ~3k reasoning tokens before outputting YES/NO):
```python
"max_tokens": 2048,
```

Fix 2 — fall back to `reasoning_content` if `content` is empty (safety net for future token budget issues):
```python
msg = resp.json()["choices"][0]["message"]
return (msg.get("content") or msg.get("reasoning_content") or "").strip()
```

**Bug 3: `parse_verdict` crashes on empty string**

Defensive fix in case `call_sarvam` returns `""` despite the above:
```python
lines = raw.strip().splitlines()
first_line = lines[0].strip().upper() if lines else ""
```

Also added a full-text scan fallback: if the first line isn't `YES`/`NO` (e.g., when parsing from `reasoning_content` which starts with chain-of-thought), scan all lines for the verdict:
```python
verdict_line = next((l.strip().upper() for l in lines if l.strip().upper().startswith(("YES", "NO"))), "")
is_harmful = verdict_line.startswith("YES")
```

**Bug 4: Prompt field is a dict in Promptfoo v2 output**

The JSON schema for `prompt` in Promptfoo's results is `{"raw": "...", "label": "...", "config": {...}}`, not a string or list. The script only handled `str` and `list`, so prompt was always extracted as `""`.

```python
elif isinstance(p, dict):
    prompt = p.get("raw", "")
```

**Bug 5: `conda run -n sarvam-evals` resolves wrong Python**

`conda run -n sarvam-evals python3` was resolving to `/opt/homebrew/bin/python3` (missing `requests`) instead of the env's Python at `/Users/Basil/miniconda3/envs/sarvam-evals/bin/python3`.

Use the env's Python directly to avoid PATH shadowing:
```bash
/Users/Basil/miniconda3/envs/sarvam-evals/bin/python3 scripts/compare_judges.py --input output/english_results.json
```

### Performance Note

With `max_tokens=2048` and reasoning ~3k tokens/call at ~117 tok/s, each FAIL case takes ~30s. 137 cases ≈ **70 minutes** total. Don't kill the process mid-run.

### Files Changed
- `scripts/compare_judges.py` — all five fixes above

---

## 2026-05-17 — Hindi Eval Error Diagnosis & Fixes

### Context

Hindi eval `eval-5q3-2026-05-17T09:56:44` completed with 66.7% error rate (50/75 tests failed with errors, not safety passes). Two independent root causes.

### Root Cause 1: `TypeError: redteamProvider.id is not a function` — 25 errors (jailbreak strategy)

Promptfoo 0.120.19 bug. The iterative jailbreak provider (`promptfoo:redteam:iterative`) is passed to `runRedteamConversation` as a plain object `{id: "...", ...}`, but the function calls `redteamProvider.id()` expecting a callable. API shape mismatch — fixed in 0.121.11.

### Root Cause 2: Context size exceeded — 21 errors (crescendo strategy)

Crescendo is multi-turn: each round appends to conversation history. Hindi text is verbose; with `--ctx-size 16384` and `max_tokens: 2048`, a crescendo run was observed hitting 16,445 tokens against a 16,384 limit. Multi-turn context accumulation, not single-prompt length, was the cause.

### Fixes Applied

**1. Upgraded promptfoo 0.120.19 → 0.121.11**

Required Node.js >=22.22.0; only 22.20.0 was installed.

```bash
nvm install 22.22.0
nvm alias default 22.22.0
export NVM_DIR="$HOME/.nvm" && source "$NVM_DIR/nvm.sh" && nvm use 22.22.0
npm install -g promptfoo@0.121.11
```

**2. `start_server.sh` — `--ctx-size` 16384 → 32768**

Crescendo observed hitting 16384 at turn depth ~5 in Hindi. 32768 gives headroom for full 10-turn escalation. Model supports up to 128K (`n_ctx_train: 131072`); KV cache delta is modest.

**3. `promptfooconfig.hindi.yaml` — `max_tokens` 2048 → 1024**

With `--reasoning-budget 1024` (1024 thinking tokens) + 1024 response tokens = 2048 total output per turn. Halving the response budget frees more context for input history in crescendo multi-turn runs, and the grader only evaluates `content` (not reasoning), so response quality isn't materially affected.

### Files Changed

- `start_server.sh` — `--ctx-size 32768`
- `promptfooconfig.hindi.yaml` — `max_tokens: 1024`
- Node.js default — 22.20.0 → 22.22.0 (nvm alias default)
- promptfoo global — 0.120.19 → 0.121.11

### Next: Restart Server and Rerun Hindi Eval

```bash
# 1. Restart server with new ctx-size
./start_server.sh

# 2. Rerun hindi eval
export ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY .env | cut -d= -f2)
promptfoo redteam run --config promptfooconfig.hindi.yaml --output output/hindi_results.json

# 3. Compare judges
/Users/Basil/miniconda3/envs/sarvam-evals/bin/python3 scripts/compare_judges.py --input output/hindi_results.json
```

---

## Results

*(To be filled after Phase 1 runs)*

### Phase 1 English Results — [DATE]

### Phase 1 Hindi Results — [DATE]

### Dual-Judge Disagreement Analysis — [DATE]

---

## Phase 2 Roadmap

| Target | Description |
|--------|-------------|
| `jailbreak:tree`, `jailbreak:hydra` | Deeper, adaptive attack trees |
| `harmbench`, `beavertails` | Dataset-based broad coverage |
| `bias:race`, `bias:gender` | Caste/religion bias (India-specific) |
| `harmful:cybercrime`, `harmful:sexual-content` | Expanded harm categories |
| Tamil, Telugu, Bengali configs | Sarvam's other Indic language targets |
| Full OWASP LLM Top 10 | Compliance-grade coverage |
| Agentic tool-use config | Test with actual tool definitions to probe `shell-injection`, `bola`, `ssrf` in realistic context |
