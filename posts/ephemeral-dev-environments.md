# How I set up containerized dev environments you can spin up in seconds for Antigravity CLI

**tl;dr:** I set up a way to spin up containerized dev environments for AI
agents with limited, controlled access. They only get the credentials and
network access they need, so they can keep working without asking for
permission, and without compromising security. Local sessions start in seconds,
and the same image deploys to Cloud Run when I want it off my laptop.

![The dashboard running five cloud sessions in parallel, with live terminals](../assets/dashboard.png)

## Avoiding permission fatigue

With Antigravity CLI you have a few options. You can approve each request
manually. You can put it in `accept-edits` mode so it approves certain things
on its own. Or you can run it with `--dangerously-skip-permissions` and not
approve anything.

The third option is convenient, but it is risky. Running on your main machine
with your credentials, it could do a lot of damage, not just to your local
environment but to your accounts: GitHub, email, whatever else you are signed
into.

So I decided to put it in a container instead, so I can run it with
`--dangerously-skip-permissions` without approving every single request. It
gets a separate GitHub account and only the specific keys it needs. My Slack
key is read-only, for example. Its blast radius is limited.

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

Secrets live in one folder on my machine, one file per environment variable, so
an agent only ever sees the keys I put there. Local sessions get them as env
vars, and deploying syncs them to Secret Manager. The cloud mirrors that folder, so if a key is gone locally, the next
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
start connections back to them. Same idea as the rest of the setup: it gets
exactly the access it needs and nothing in the other direction.
