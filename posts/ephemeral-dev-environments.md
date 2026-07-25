# How I set up containerized dev environments you can spin up in seconds for Antigravity CLI

**tl;dr:** I gave each AI coding agent its own container, so it can run with
permissions switched off without ever touching my machine. A local session
starts in seconds, and the same image deploys to Cloud Run when I want it off
my laptop. Both are managed from one dashboard. Everything here is in
[this repo](https://github.com/ykdojo/antigravity-cloud-run).

![The dashboard running five cloud sessions in parallel, with live terminals](../assets/dashboard.png)

## Permission fatigue

Permission fatigue is a real thing. Lydia from Anthropic
[described it](https://www.youtube.com/watch?v=6ERUGFurDHY&t=1444s) on Google
Cloud Tech, in an episode I was on too:

> If Claude asks you questions every time, you won't read them as much
> anymore, because you're kind of, "you've asked me 100 times now, sure, just
> go ahead." That's permission fatigue, which is also dangerous.

One way to fix it is an isolated environment. That can be a separate computer,
but a container is more convenient. It is extremely hard to escape a container
into the host machine, and everything is contained, which is in the name. So
it is a secure environment where you can give the agent access only to the
things it should have, including a separate GitHub account, which is what I
like to do. Then you can let it run on its own with
`--dangerously-skip-permissions`.

## The setup

One container, one agent, one conversation. Keep it simple like that. The agent
is Google's [Antigravity CLI](https://antigravity.google/), or `agy`. Sessions
are isolated from each other, so you can run several at once without
interference. That is how I ran
[the collaboration experiment](../experiments/collaboration-vs-wisdom-of-the-crowd/)
with five agents in parallel.

Each session is a web terminal, ttyd plus tmux, so you can open it in a browser
tab or watch it live in the dashboard above.

Auth and conversation history persist per session. Locally they sit on my
machine through a volume mount. In the cloud they go to a Cloud Storage bucket
per session, synced every 60 seconds and again on shutdown, so restarting a
session keeps its history.

Secrets live in one folder on my machine, one file per environment variable.
Local sessions get them as env vars, and deploying syncs them to Secret
Manager. The cloud mirrors that folder, so if a key is gone locally, the next
deploy deletes it from the cloud too. With two machines you want to deploy from
the one that has the keys you want live.

## Why the cloud and not just local containers

Local containers are already enough to be safe. The cloud gives you more
separation. It is a separate machine, so it does not affect whatever you are
doing locally, and you do not have to worry about your own machine running
while the job runs. Your laptop can be off and the job keeps going, as long as
you deploy the session always-on, since sessions otherwise scale to zero when
idle. You reconnect later to get the state of that job.

Sessions are IAM-gated and never public. You reach one with
`gcloud run services proxy`, which tunnels the web terminal to a local port, so
you can talk to agy and use its shell.

## Reaching other ports

Cloud Run gives a service exactly one port, so a dev server running inside a
session is not reachable from outside. Each session joins my private Tailscale
network as an inbound-only node instead. A server on port 3000 is then at
`http://<session-name>:3000` from my own machines, and the container cannot
start connections back to them.
