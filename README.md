# Stone

Stone is an iPhone app that can carry any Fossil repository and work with it
offline. Fossil is a version-control system: one file holds a project's
history, along with its wiki, forum and tickets (its list of bugs and
requests), and two copies of it can sync with each other. Stone keeps such
copies on the phone, so a person can read, write and reply with no network.
When the network returns, Stone syncs what they wrote.

## What it's for

Stone is meant for anyone, not only the maintainers who look after a
project's software. It is the one iPhone app in this program: a set of
related projects that keep their records in Fossil and work with AI agents.
It stays as thin as it can, with as little code of its own as possible. The
knowledge lives in the repositories, and Stone only carries them.

Stone has a second purpose, called Chronicle. Chronicle is a journal
repository: an ordinary Fossil repository that holds a person's own record.
Stone is meant to write a person's life into it and search it across time:

- journal entries and calendar events, as dated notes;
- health and location, as wiki pages;
- photos and voice notes, as attachments (files added to the repository).

Stone's own job there is to bring in what the phone's sensors capture, such as
location and speech turned into text. The record stays in Fossil, where the
person controls it.

## What it's made of

- **Fossil**, built into the app as a library, so every repository works on
  the phone without a server. The app calls Fossil through a bridge, a
  small piece of C code that passes requests between the app and Fossil:
  [ios/FossilBridge/StoneFossil.c](ios/FossilBridge/StoneFossil.c).
- **LibreSSL**, which lets the built-in Fossil sync over HTTPS (secure web
  connections).
- **Swift and SwiftUI**, Apple's language and screen toolkit, for the app's
  screens, in [ios/Stone](ios/Stone).
- **Xcode Cloud**, Apple's build service. It builds Stone from this
  repository's trunk (the main line of work) and delivers each build to the
  phone through TestFlight, Apple's channel for test builds.
- **Linux-side tests.** Scripts in [scripts](scripts) build the same Fossil
  and bridge on Linux and test them there. [ci.cr](ci.cr) runs them; it is
  written in Crystal, the language this program uses for its own tools.

## How it's shaped

The app opens on a list of the repositories it holds. A person can sync each one or browse its
Fossil web pages, which the app serves from the copy on the phone. They can
also open the same pages on the repository's server, inside Stone, signed in
with the login they gave Stone for it.

Conversations are forum threads in which a person talks with an agent session:
an AI program working on a project. Stone shows each thread as a chat. It
marks whether the session is running, idle (waiting for the person's reply)
or ended, and it shows the
session's steps under the post that started them. A reply written offline
waits on the phone and goes out with the next sync.

Each change comes with a hand check: a short test a person does on the phone.
The checks are listed on the
[Hand checks](https://ollama.openbeagle.org/stone/wiki?name=Hand+checks) wiki
page. Each line says where to go in the app, what to do and what to see.

## What success looks like

- **Any repository, offline.** After one clone over the network, browse and
  write with no network, and sync when it returns. Done: Fossil runs inside the app, and the Linux tests sync through the same
  bridge ([scripts/linux-crosslink-test.sh](scripts/linux-crosslink-test.sh)).
- **Conversations with sessions.** Read and answer agent sessions, offline
  too. Done: in builds since November 2026, with checks on
  [Hand checks](https://ollama.openbeagle.org/stone/wiki?name=Hand+checks).
- **Chronicle.** Journal entries, calendar events, health, location, photos
  and voice notes recorded into a journal repository. Not yet: the design is
  in [docs/design/chronicle-readiness.md](docs/design/chronicle-readiness.md),
  and the app reads none of these sensors yet. It waits on the apps gate
  below: its repository is private.
- **Search across time.** Find anything in the journal by when it happened.
  Not yet.
- **Project apps.** Stone carries apps in its own build, WebAssembly modules
  built from a project's check-in, as an OCX node does. The four-squares
  button lists them, each with an on/off switch, and an app works over the
  repositories on the phone. In progress: the list and switch, with a small
  test app; Stone Media and ocx-console come next
  ([plan](https://ollama.openbeagle.org/stone/forumpost/df2aca7b58)).
  Gate: an app acts as the person's login in every repository on the phone,
  which suits public data, all Stone carries today. Before a private
  repository such as Chronicle goes on a phone, stability and isolation must
  be shown working: what an app can reach across repositories, and that one
  repository's data can't leak through another's app
  ([maintainer](https://ollama.openbeagle.org/stone/forumpost/b818022970)).

## The virtues behind it

Like every project in this program, Stone follows the four virtues of
[OCX](https://ollama.openbeagle.org/ollama/doc/trunk/README.md), the protocol
and tools through which people and agents work together on these projects in
Fossil:

- **Clearly stated:** anyone can tell what each part does. Each change
  comes with one hand check that says where to look and what to see.
- **Loosely coupled:** each part can be swapped without breaking the rest.
  Stone holds no repository's knowledge itself, and no repository is built
  into it.
- **Demonstrably verified:** every claim is shown working, not just stated.
  Each build is checked by hand on the phone, and the bridge is tested on
  Linux.
- **Parsimoniously bounded:** it does no more than it needs to. Stone carries
  repositories and brings in the phone's sensors. Everything else belongs to
  the repositories.
