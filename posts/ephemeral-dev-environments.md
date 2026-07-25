# How I set up containerized dev environments you can spin up in seconds for Antigravity CLI

**tl;dr:** I set up a way to spin up containerized dev environments for AI
agents with limited, controlled access. They only get the credentials and
network access they need, so they can keep working without asking for
permission, and without compromising security. Local sessions start in seconds,
and the same image deploys to Cloud Run when I want it off my laptop.

![The dashboard running five cloud sessions in parallel, with live terminals](../assets/dashboard.png)

## Avoiding permission fatigue

With Antigravity CLI you have a few options. You can approve each request
manually. You can configure it in such a way that certain types of requests are
accepted automatically. Or you can run it with `--dangerously-skip-permissions`
and skip approval entirely.

The third option is convenient, but it is risky. Running on your main machine
with your credentials, it could do a lot of damage, not just to your local
environment but to your accounts: GitHub, email, whatever else you are signed
into.

So I decided to put it in a container instead, so I can run it with
`--dangerously-skip-permissions` without approving every single request. It
gets a separate GitHub account and only the specific keys it needs. For
example, you can give it read-only keys for your accounts if you don't want it
to be able to post by itself. That way, its blast radius is limited.

## What it gets access to

First, it gets my OAuth token for Antigravity, so that it's able to use my
subscription's usage quota. There is no API key option today, only that token
file. Until this feature is implemented
([related](https://github.com/google-antigravity/antigravity-cli/issues/78)
[requests](https://github.com/google-antigravity/antigravity-cli/issues/592)),
this is what I decided to go with. You log in once inside
a container, and every session after that is seeded from that token, locally and
in the cloud.

You also give it a list of environment variables, and they get injected into
the container automatically every time you spin up a session, locally or in the
cloud.

I also built a dashboard to manage sessions, so I can spin one up, stop it, or
delete it in a few seconds. That is the nice thing about containers. It is easy
to throw one away and start fresh.

Conversation history carries across sessions, as long as you name the session
the same way. Locally it lives on my machine through a volume mount.

On Cloud Run it works pretty much the same way. The keys are synced to Secret
Manager and wired into the service as environment variables, and conversation
history goes to a Cloud Storage bucket, one per session, synced every 60
seconds and again on shutdown. So a session you restart picks up where it left
off, same as local.

Cloud sessions are IAM-gated and never public. You reach one by running
`gcloud run services proxy`, which opens a local port on your machine and
tunnels it to the container, so you open `localhost` in your browser and talk
to the agent and its shell from there. The dashboard does this for you per session.

## Adding it to your Tailscale network

This part is optional, but if you already use Tailscale I recommend it for
this.

The reason you need it is that Cloud Run only lets one port per service be
reachable from outside, and that port is already taken by the web terminal. So
if the agent starts a server inside the session and you want to look at it,
there is no way in. Tailscale is the workaround.

Each session joins my private network as its own node, so a server on port 3000
is at `http://<session-name>:3000` from my laptop, or from any machine on my
tailnet. Because of how the access rules are set up it only works one way: I
can reach the container, and the container cannot reach my machines. Worth
keeping in mind. It works the same way for local containers.

When the Tailscale key is present, the session also writes its own address into
the agent's `AGENTS.md` on startup, so the agent knows where it lives and can
hand you a working URL instead of `localhost`. If the key is not there, that
section is left out entirely.

## What is it good for?

People ask me this, and the assumption behind the question is usually that I
want something running 24/7. I don't, not really.

What I do want is somewhere I can let an agent go free, for long running tasks
and for tasks I would rather not run on my main machine. Research is the
obvious one: going through a bunch of YouTube videos, or a bunch of Reddit
threads. I don't necessarily want that running from my main machine.

Building a feature on a side project is another one. I don't want it using my
main machine's resources, so it runs in a container instead, either locally or
in the cloud.

The one I keep coming back to is letting it look through GitHub and put up a
quick fix as a PR. It has its own account, so it sends the PR to me and I
review it. That workflow has been pretty effective.
