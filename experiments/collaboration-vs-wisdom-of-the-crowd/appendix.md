# Appendix: prompts, image, and data

Companion page to [the main post](README.md). Everything here is exactly
what the experiment ran, minus anything that could lead to Project Euler
answers. Per the site's rules we publish whether each run was correct and how
long it took, but never the answers themselves, and no agent transcripts.

## The solver prompt (both methods)

Every agent, in both methods, received this base prompt:

```text
Solve the Project Euler problem whose full statement is in /home/agrun/workspace/problem.html (verbatim HTML from Project Euler, with inline LaTeX). Any additional files the problem requires are also in /home/agrun/workspace. Read the statement carefully first.

Rules:

- Work in /home/agrun/workspace. Write and run programs to compute the answer; do not answer from memory or by hand alone.
- Verify before submitting: your program must reproduce any example values given in the problem statement, and where feasible confirm the result with a second method or a brute-force check on small cases.
- STRICT: make no network requests of any kind (no curl, wget, pip install, or anything else that touches the network). Python 3 with sympy, numpy, and gmpy2 is already installed.
- When you are confident, call the submit_final_answer tool with the answer (digits only) and a brief summary of your approach and verification. This tool is the only way to submit; printing the answer does not count.
```

## The collaboration addendum (collaborative method only)

Agents in the collaborative method additionally received this, with {N} = 5:

```text
You are one of {N} agents independently solving this same problem in
parallel. You can communicate with the others:

- To share an insight with all other agents, call the broadcast_insight
  tool. A broadcast interrupts every other agent, so use it only for the
  most crucial information: a verified structural insight, a confirmed
  intermediate/anchor value, or a dead end that would cost others real
  time. There is no hard limit; use your judgment.
- Broadcast early, not only at the end. The moment you verify an approach
  against the statement's example values (even if your full computation is
  still running), or conclusively rule out an approach after real effort,
  share that finding immediately. A mid-run insight can redirect the whole
  group while there is still time to use it; the same insight shared only
  when you finish helps no one.
- Other agents' broadcasts may occasionally reach you as an intercepted
  tool call explaining itself as a [BROADCAST]. That is normal. Treat a
  broadcast as another agent's belief, not verified truth: weigh it
  against your own evidence, and feel free to use it, test it, ignore it,
  or reply with a broadcast of your own.

Your submission via submit_final_answer remains yours alone.
```

Delivery mechanism: broadcasts are written to per-agent inbox files on a
shared mount, and a PreToolUse hook delivers an unread message by intercepting
the receiving agent's next tool call. The submit_final_answer and
broadcast_insight tools are provided by a small MCP server.

## The container image

One container per agent, five concurrent containers per set:

```dockerfile
# Slim solver image for the wisdom-of-the-crowd experiment.
# Derived from ykdojo/antigravity-cloud-run's image, minus everything a headless
# solver doesn't need (Playwright/Chromium, ttyd/tmux, gh, Slack, Node).
FROM ubuntu:noble

ARG DEBIAN_FRONTEND=noninteractive

# Pinned agy release. The public installer only fetches "latest", so we skip it
# and download the versioned artifact directly, verifying its sha512 (values
# from https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/<platform>.json).
ARG AGY_BUILD=1.1.3-5723946948100096
ARG AGY_SHA512_ARM64=20b297fddf0feabfe982de610250923cf35b9c1756e36af006876b2a4a475a7cc59a58c6f04d91e96ea31a422b60020c444d443f163337baee69ffc9b6f33601
ARG AGY_SHA512_AMD64=f84f04fa50c7b3b257c6d091b3f66425e07bf7aa556fe2f9db5899aa5420511d0eadf72dfeb25816ad92213b06e5039b7d33e8025cfc2f1b3d77fb33f2d161be

# ripgrep is preinstalled because agy otherwise tries to install its own copy
# co-located with the binary, which is root-owned here.
# The Python math stack lets solvers work without pip (no-network rule).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq ripgrep \
        python3 python3-pip python3-sympy python3-numpy python3-gmpy2 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash agrun

# Install agy root-owned: its background self-updater replaces the binary in
# place and has no off switch, so running as agrun with a root-owned binary is
# what keeps the pin effective.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      arm64) dir=linux-arm; file=cli_linux_arm64.tar.gz; sha="$AGY_SHA512_ARM64" ;; \
      amd64) dir=linux-x64; file=cli_linux_x64.tar.gz; sha="$AGY_SHA512_AMD64" ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/agy.tar.gz "https://storage.googleapis.com/antigravity-public/antigravity-cli/${AGY_BUILD}/${dir}/${file}"; \
    echo "${sha}  /tmp/agy.tar.gz" | sha512sum -c -; \
    tar -xzf /tmp/agy.tar.gz -C /tmp; \
    install -o root -g root -m 755 /tmp/antigravity /usr/local/bin/agy; \
    rm -f /tmp/agy.tar.gz /tmp/antigravity

COPY mcp_submit.py /opt/harness/mcp_submit.py

USER agrun
WORKDIR /home/agrun

# ~/.gemini is a per-run mount; the runner seeds these defaults into it with
# cp --update=none. onboarding.json skips the first-run wizard.
COPY --chown=agrun:agrun setup/AGENTS.md /home/agrun/.gemini-defaults/AGENTS.md
COPY --chown=agrun:agrun setup/settings.json /home/agrun/.gemini-defaults/antigravity-cli/settings.json
COPY --chown=agrun:agrun setup/mcp_config.json /home/agrun/.gemini-defaults/config/mcp_config.json
COPY --chown=agrun:agrun setup/onboarding.json /home/agrun/.gemini-defaults/antigravity-cli/cache/onboarding.json

RUN mkdir /home/agrun/workspace

CMD ["sleep", "infinity"]
```

## The data

- [runs.csv](data/runs.csv): all 300 runs (30 problems, 2 methods, 5 agents)
  with outcome (correct, wrong, or abstain) and duration in seconds.
- [broadcasts.csv](data/broadcasts.csv): number of broadcast messages sent per
  collaborative-method set (104 total across the 30 problems).
- [results-summary.md](results-summary.md): the per-problem summary table
  (correct counts, abstentions, vote outcome, median, mean, and worst times).
