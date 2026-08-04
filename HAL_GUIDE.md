# The Hal Guide

Hal is an on-device AI assistant built around one idea: showing you how the AI actually works, rather than hiding it. This guide is the companion to that idea. It explains what you see on screen, and it documents the three ways you can drive Hal directly: the Developer API, RoboRunner, and the command line.

This guide is generated alongside Hal's own source code, and its command reference is built directly from the app's command catalog, so what you read here matches what the app actually does.

> This document is bundled with Hal and is also open-source. If you build your own Hal, you are meant to build on this guide too.

---

## How this guide is organized

1. **Screens and settings**: a tour of everything you can see and touch in the app, the top bar, the composer, the signals on each reply, and every settings screen.
2. **RoboRunner**: the on-device automation language and runner in the Lab.
3. **Command API**: the local HTTP server that lets another app or script drive Hal.
4. **Command line**: the `hal` terminal command, a thin client for that same API.
5. **Command reference**: every command verb, generated from the app's catalog.
6. **Architecture**: how Hal works inside, memory, models, prompt building, thinking, and thermal pacing.

---

## The one idea behind the three doors

The Developer API, RoboRunner, and the `hal` command line look different, but they are three doors into the **same** command interpreter. The exact same command verbs work through all three. Learn a verb once and it works everywhere:

- The **Developer API** is a local HTTP server. Another app or a script sends a verb and reads the reply.
- **RoboRunner** is an in-app script editor. You write a short script of verbs and Hal runs it on the device.
- The **`hal` command line** is a small terminal command that forwards a verb to the API and prints the reply.

Because there is one interpreter, there is one command reference (below), and one safety model.

### Safe and Advanced

Commands that only read or adjust settings always work. Commands that change or delete data are **destructive**, and they are gated:

- In **Safe mode** (the default, and where Hal resets on every launch), destructive commands are refused outright.
- In **Advanced mode**, a destructive command runs only if you add a trailing confirmation marker (` --yes` or ` CONFIRM`).

Switch modes with `SET_SAFETY:safe` or `SET_SAFETY:advanced`. In the command reference, destructive commands are marked **[Advanced]**.

---

## Screens and settings

This is a tour of everything you can see and touch in Hal: what each control does, what each on-screen signal means, and how his memory behaves. Everything here reflects Hal's guiding idea, transparency as architecture. The signals below exist so that when something happens under the hood (memory gets condensed, a device gets warm, a turn gets stopped), you can see it and understand it rather than guessing.

A note on wording: Hal's on-screen text says "device" rather than naming a specific product, because Hal runs on iPhone, iPad, and Apple Silicon Macs.

You can also just ask Hal any of this in chat. This guide is part of his self-knowledge, so questions like *"What does the red scissors mean?"* or *"Did you save that answer I stopped?"* get answered from it directly. That is the most Hal way to learn Hal: ask him.

### The chat screen at a glance

- **Your messages** appear in a gray bubble on the right.
- **Hal's replies** appear on the left, as flowing text with no bubble around them, so his longer answers read like a document.
- Along the top is a **two-row header**: the current thread's title on its own line, and below it a **row of icons** (next).
- Under each message is a small **footer line** with the date, time, and turn number. Hal's replies also name the model that produced them (for example "Apple Intelligence"). This footer is where Hal's status signals appear.
- Under Hal's replies is a **row of action icons** (copy, details, read aloud, and more).
- At the bottom is the **composer**: the text field where you type, with the send button to its right.

When you send a message, that message scrolls up to the top of the view once, and then you are in full control of scrolling. Hal's reply streams in below it.

### The top bar (the icon row)

The header shows the thread title, then a row of icons. From left to right:

- **Threads** (three horizontal lines): opens the slide-out list of all your conversations.
- **Thermal indicator** (a filling thermometer): appears **only when the device is warm or hot**. When cool it is hidden entirely. Tap it for a plain-language note on how warm things are and what Hal is doing about it.
- **Thinking** (a brain): turns **thinking mode** on and off. Bright when on, dim when off.
- **Help** (a life ring): opens **Help Mode**, a menu of focused help topics. Bright when a topic is active, dim when off.
- **Privacy Lock** (a closed or open padlock): a live indicator of whether your data could leave the device right now. Tap it for the explanation.
- **Settings** (a gear): opens the Settings screen.

The brain and the life ring sit side by side on purpose: brain for thinking, life ring for help. The thermometer, when it appears, always sits to the brain's left, so it never wedges between the two mode toggles.

### The composer: sending and stopping

**Sending.** Type in the field and tap the **paper-plane** button to send. The field grows to fit a few lines as you type. The send button is disabled while there is nothing to send.

**Stopping.** While Hal is generating a reply, the paper-plane turns into a **stop button** (a filled circle with a square inside). Tap it and Hal stops.

- On Hal's **local models (MLX)**, the stop is essentially immediate.
- On **Apple's on-device model**, the stop takes effect at his next update, which is usually well under a second.

The stop signal reaches the reply no matter how it was started (the composer, the Lab, or the Developer API). When Hal stops, whatever he had written so far stays on screen, and the button turns back into the paper-plane so you can send again. The short version of what happens in memory is: **nothing from a stopped turn is saved** (details below, under stopped turns).

### Turn numbers, model names, and seats

- The **turn number** counts the exchanges in the current conversation.
- The **model name** on Hal's reply tells you which mind produced it (Apple's on-device model, or one of the local models). Because Hal can run several different models, this attribution is always visible. Hal never hides which model spoke.
- In **Salon Mode**, a reply's footer also shows **"Seat N of M"** to say which voice spoke, and **"Host"** when the reply is the moderator's summary.

A **stopped turn does not advance the turn count.** Because it is not saved, the next real reply reuses that number.

### Thinking mode and the reasoning panel

Hal can answer in two styles, toggled by the **brain button** in the top bar:

- **Brain off (the default):** Hal replies directly.
- **Brain on (thinking mode):** Hal first *thinks*, working through the question in a bounded reasoning pass, and then writes his answer from that reasoning. This is slower and more deliberate. Thinking mode works on **every** model.

Tapping the brain also narrates the change in the chat and shows a short popover explaining the new state.

When thinking mode is on, Hal's reasoning appears in a **"Thinking" panel** above the answer. The panel is **shown expanded by default** (on a transparency project the reasoning is often the part most worth reading), and you can collapse or expand it by tapping it. That choice is remembered across launches.

**The reasoning is never saved to memory.** Only Hal's final answer becomes part of the conversation and his memory; the thinking trace is shown to you for transparency and then discarded. Thinking is also more work for the device, so on heavier models Hal deliberately paces himself in thinking mode to stay cool.

**Thinking Cap.** How long Hal is allowed to think before he must answer is tunable per model, in Settings, from 100 to 500 tokens (default 300). A lower cap runs cooler; a higher cap lets him reason longer.

Thinking mode is **not available in Salon Mode.** Watching one model reason and then answer does not fit a multi-voice round, so the brain dims there and, if you tap it, explains why instead of toggling.

### Help Mode (the life ring)

**Help Mode** is a focused way to ask Hal about his own tools and architecture. Tap the **life ring** and pick a topic:

- **RoboRunner** (help with Hal's on-device automation scripts)
- **Command API** (help with the local Developer API)
- **Command Line** (help with the `hal` terminal command)
- **Architecture** (questions about Hal's own source code)

When a topic is active, Hal sets his ordinary self aside for that topic: he answers **only from his own documentation for that one subject**, skipping his personal memory so the answer comes straight from the docs rather than from memory or general knowledge. He says so plainly when you enter and leave. Pick "Leave Help Mode" (or tap the life ring again) to return to normal.

Help Mode is a per-session choice and is deliberately **not** remembered across launches, so you are never left in it by surprise. It is distinct from asking Hal who he *is* (his identity, values, or sense of self); those questions always go the normal full-context route, with his whole self intact.

### Reading a message footer (the signals)

The footer under a message normally shows the date, time, turn number, and (for Hal's replies) the model name. While Hal is still generating, the footer instead shows a spinner, **"Processing..."**, a live timer, and the name of the model producing the reply, so you always know which engine is at work in real time. After a reply that used thinking mode, the footer may also show **"Inference X.X sec"**, the time that turn took.

Sometimes a small **glyph** appears at the end of the footer line, and the whole line changes color. Each glyph means something specific. The whole line is tappable, so you can hit anywhere on it to see the explanation, not just the icon.

**Stop circle, red: the turn was stopped.** A red circle-with-a-square on one of Hal's replies means **you stopped that reply while he was generating it.** Tapping the footer explains what happened to it. A stopped turn is kept on screen but is **not saved to Hal's memory**.

**Scissors, red: memory was truncated.** A red scissors means that, for this one turn, part of what Hal knows was **cut** to fit the model's context window rather than intelligently condensed. This happens only in a rare failure case: the model that normally condenses memory was unavailable, took too long, or produced a result that did not pass Hal's own verification, so Hal fell back to a hard cut at the size limit. **Important:** Hal's *full* memory is always preserved in his database. The cut only affects what the model saw for that single turn. Tap the footer for the specific detail, including exactly which parts of the prompt were affected.

**Compress bars, gray: memory was condensed.** A gray "compress" glyph (horizontal bars) means Hal's memory was **too large for this model's context window, so it was intelligently condensed** by the model itself to fit, and it succeeded. This is the normal, healthy version of the same situation the scissors warns about. Nothing was cut crudely; it was distilled. Smaller on-device models see this more often than large ones. Tap the footer for what was condensed.

**Why gray versus red?** Gray (condense) is routine and fine. Red (scissors, or the stop circle) is a strong signal Hal wants you to notice, so he colors the whole footer line to make it hard to miss. If both a stop and a condensation apply to the same reply, the stopped signal takes priority.

### The action row under Hal's replies

Under the footer of each of Hal's finished replies is a row of small tappable icons. They are also available by long-pressing (or right-clicking) a message:

- **Copy message:** copies just this reply's text.
- **Copy thread:** copies the whole conversation.
- **Copy message with details:** copies this reply together with the behind-the-scenes information (the full prompt that produced it and the memory snippets it used).
- **Copy thread with details:** the whole conversation with those details included.
- **Toggle inline details:** expands or collapses a compact, color-coded breakdown right under the message.
- **Prompt details:** opens the full Prompt Details viewer.
- **Read aloud:** speaks the reply out loud; the icon fills while it is speaking, and tapping again stops.

Your own messages have a smaller set (copy message, copy thread, and the two detailed copies).

### Seeing exactly what Hal was given (Prompt Details)

Hal will show you the *exact* prompt he was handed for any reply. This is transparency in its purest form: you can see precisely what he saw.

The **Prompt Details viewer** opens a color-coded, collapsible breakdown of the assembled prompt. Each part has its own color and label:

- **System Prompt** (purple): Hal's persona and framing.
- **Temporal Context** (orange): the date, time, and how long the session has run.
- **Conversation Summary** (yellow): a condensed summary of earlier conversation.
- **Self-Awareness** (teal): runtime facts like the current turn count.
- **Self-Knowledge** (pink): Hal's persistent traits and reflections.
- **Memory Snippets (RAG)** (green): the long-term memories retrieved for this turn.
- **Conversation History** (blue): the recent turn pairs.
- **User Message** (gray): the message that triggered this reply.

**Inline details** shows the same breakdown, in the same colors, compactly under the message without opening a sheet. It is a per-app toggle, so turning it on shows it under every reply until you turn it off.

### Stopped turns, and what happens to them

When you stop Hal mid-reply, Hal treats that turn as one you chose to take back. The design principle is **consistency between what Hal is told and what Hal is allowed to keep**: he should never be handed a half-exchange in the moment that he is then barred from remembering.

So a stopped turn:

- **Stays on screen** as an honest record, marked with the red stop glyph.
- Is **not saved to Hal's long-term memory**. The user message written at the start of the turn is deleted again, so nothing from the turn is persisted.
- Is **not included as context** in the rest of the conversation. Hal genuinely carries no memory of it. If you ask a follow-up that depended on it, Hal will not know, because for him it did not happen.
- **Does not advance the turn count.**

If Hal was stopped before he had written anything, his bubble shows, in his own voice: **"You stopped me before I could reply."** If he had already written part of an answer, that partial text is what stays on screen. Tapping the footer of a stopped reply opens a note titled **"Response stopped"** that explains all of this.

**If you want Hal to keep something, let the reply finish** (or ask again). This is the honest trade: stopping is a clean "never mind," not a partial save.

### Models, the minds Hal can use

Hal can think with more than one model, and you choose which one is active.

- **Apple's on-device model ("Apple Intelligence"):** built into the operating system, always available, fast. This is Hal's default.
- **Local MLX models:** larger open models you download onto the device. The curated set currently includes options such as Gemma, Qwen, Llama, Dolphin, and a larger, heat-calibrated model called Ternary Bonsai 8B. You can also add other MLX models from Hugging Face by searching in the Model Library. Untested models are marked as experimental.

You switch, download, and manage models in **Settings, Browse Model Library**. Each model row shows a status dot (green means downloaded and active), a **Select** or **Active** control to switch to it, a **Download** button for models not yet on the device, and a **Delete** option to reclaim space (you switch away from a model before deleting it). Downloads continue even if the app is suspended.

Models are **shared across the AI family** (Hal and its sibling apps, Posey and Thomas: AI Camera) through a common on-device store, so a model downloaded once can be used by each without a second copy. When you clear models, Hal tells you honestly which files are only his (and will be removed) and which are still in use by a sibling app (and will stay).

All of Hal's models run **on the device**. Nothing is sent to a server for the local models. (See Privacy Lock, below, for the one honest caveat about Apple Intelligence and the network.)

The Model Library also lets you choose the **embedding model** that powers how Hal recalls your memories. Apple's built-in option is always available; stronger optional downloads (such as Nomic Embed Text and Mixedbread mxbai) can be selected, and switching between them is instant and non-destructive.

### Memory, what Hal remembers and how

Hal's memory is one of the things that makes him Hal. It has layers:

- **Conversational memory:** what was actually said, stored and searchable so Hal can recall relevant earlier moments. This is the retrieval you may see referenced as "RAG."
- **Experiential and reflective memory:** distilled patterns and reflections built up over time.
- **Self-knowledge:** Hal's understanding of his own architecture. Hal can read his own source code and explain how he works.

Each turn, Hal assembles a prompt from your message plus the most relevant pieces of memory, his persona, temporal context, and any summary of earlier conversation. You can see the exact result in the Prompt Details viewer.

When that assembled memory is larger than the current model's context window, Hal **condenses** it (or, rarely, **truncates** it) to fit, and tells you with the footer signals above. **Hal's full memory is always preserved in his database regardless.** The condensing only affects what a given model sees for a given turn.

**Where the full memory lives.** Hal's complete memory always sits in the on-device database and is never thinned by condensation. The **Settings, Maintenance & Reset, Database** screen shows database figures (your total number of threads and documents), alongside the Nuclear Reset that wipes all data. There is not yet a screen that lets you browse the full stored memory content itself, only these summary figures.

**Uploading a document.** In **Settings, Import/Export, Upload Document to Memory**, you can hand Hal a document to reference. He ingests it into memory so he can recall it later. You can also **Export Thread** to share the current conversation.

**Tuning memory.** In the Single LLM Settings, you can adjust how much Hal keeps verbatim and how he weighs relevance against recency.

### Threads (your conversations)

The **Threads** panel (the three-lines icon, top left) lists all your conversations, most recent first. From here you can:

- **New Thread:** start a fresh conversation.
- **Tap a thread:** switch to it, with its full context restored. The active thread is marked with a checkmark.
- **Reset or delete a thread:** swipe a row, or tap its trash icon, then confirm. This permanently deletes that thread's messages and cannot be undone.

Each thread shows its title (seeded from your first message) and the date it was last active.

### Read-aloud (Hal's voice)

Hal can read his replies out loud, and you control the voice and speed. There are two ways to start a reading:

- The **speaker icon** in the action row reads that one reply. Tap it to start; tap it again, or tap a different reply's speaker, to stop or switch. The icon fills while that reply is being spoken.
- **Auto-read**: with "Read responses aloud" turned on, Hal speaks each reply automatically once it is finished.

The read-aloud controls live in **Settings, Read-Aloud**:

- **Read responses aloud** (a toggle): the auto-read switch above.
- **Voice**: opens a picker of every voice installed on the device for your language, showing each voice's name and quality. Leave it on **Automatic** and Hal picks the highest-quality voice available for you; or choose a specific voice. The most natural voices (the premium and enhanced "Siri-quality" voices) are the ones to look for; you can add more in the operating system's own Settings, under Accessibility, Spoken Content, Voices.
- **Speaking Speed** (a slider from Slower to Faster): sets how fast Hal reads. A short preview plays when you let go of the slider so you can hear the change.

Hal reads the prose, not the punctuation: he strips markdown, code blocks, and list markers first so the reading sounds natural. Read-aloud ducks your music or podcast rather than cutting it off, and plays even with the ringer switched off.

### Staying cool, thermal awareness

Sustained thinking, especially on large local models, heats the device. Hal watches the device's thermal state and **paces himself**, slowing generation when things get warm, so a long or heavy conversation does not push the hardware.

When the device is above normal, the **thermometer glyph** appears in the top bar and fills as it gets hotter. Tap it for a plain note:

- **Warming up:** "Your device is warming up. Hal is easing off slightly to slow the climb."
- **Hot:** "Your device is hot. Hal is slowing down to let it cool."
- **Very hot:** "Your device is very hot. Hal is pausing until it cools."

When it is cool, the glyph is hidden.

**Thermal heads-up before thinking.** Turning thinking on with a heavy model (Ternary Bonsai 8B) or an experimental model Hal has not tuned for heat shows a short warning first, and switching into such a model while thinking is already on warns you after the fact. The warning is honest about the escalation: Hal slows the model down, and if the device still gets too warm a reply can come out short or cut off, and if it gets hotter still the operating system itself steps in to protect the hardware. **None of this harms the device.** You can turn thinking off anytime with the brain button.

### Privacy Lock

The **Privacy Lock** is a live **indicator**, not a passcode. The padlock in the top bar tells you, at a glance, whether your data could leave the device right now, and it updates the instant you switch models or toggle the network (for example Airplane Mode).

- **Closed padlock (locked, private):** nothing is leaving the device. This is the case whenever you are using a **local MLX model**, or whenever the device has **no network**, whatever the model.
- **Open padlock (cloud possible):** you are using **Apple Intelligence** with a network available. Hal cannot guarantee that request stays on the device, because only Apple decides when Apple Intelligence uses its Private Cloud Compute. Hal does not claim the request *is* sent to the cloud, only that it is possible and cannot be guaranteed otherwise.

Tap the padlock for the full privacy statement (the same words in both states, since it is true in either) and a one-tap jump to the Model Library, so you can switch to a local model if you want the lock closed. In Salon Mode, the lock is closed only if **every** active seat is a local model; any Apple Intelligence seat opens it.

### Salon Mode

**Salon Mode** lets several models speak as distinct voices in the same conversation, Hal thinking through more than one mind at once. You turn it on in Settings by switching Conversation Mode from **Single LLM** to **Multi LLM (Salon)**, then open **Salon Mode Settings** to configure it:

- **Seats:** up to four seats, each assigned a model or left Empty. They speak in seat order.
- **Mode:** **Independent perspectives** (each voice answers on its own) or **Context-aware perspectives** (voices build on what came before).
- **Host:** an optional moderator seat. With a Host, one shared summary frames each round and closes the conversation (faster, but every voice starts from the Host's framing). Without a Host, each voice forms its own understanding (slower, but each perspective stays its own).

Every voice is labeled in the footer ("Seat N of M", and "Host" for the moderator's summary), and every output is part of the record. There is no hidden orchestration. While Salon Mode is on, the per-model settings (Model Framing, System Prompt, Temperature, memory tuning, and the Thinking Cap) are shown but locked, because the active "model" is now an ensemble rather than one configuration; the global toggles stay editable. Thinking mode is unavailable in Salon Mode.

### Settings, control by control

Open Settings with the **gear** icon. The screen is organized into sections.

**Personality**
- **Model framing:** a read-only view of the per-model "framing" text that Hal applies to compensate for a specific model's tendencies, with a toggle to apply it or not. Some models have no framing and simply follow the universal System Prompt.
- **System Prompt:** a full editor for Hal's universal system prompt, with a live token counter that turns amber near the limit and red at it (the field stops accepting more text at the cap rather than silently ignoring it), and a "Restore Factory Settings" option.
- **Self-Knowledge:** a toggle for whether Hal includes his persistent self-knowledge (core values, learned preferences, identity patterns, history stats, and temporal awareness) in each prompt. When on, a **Hal's Self Model** link opens a read-only view of his shareable reflections and self-knowledge.
- **Temperature:** a slider from 0.0 (focused) to 1.0 (creative). A small orange dot marks when you have moved it off the active model's tuned default.

**Chat Display**
- **Text Size:** Small, Medium, Large, or Extra Large. (Large is the default.)
- **Density:** Comfortable, Cozy, or Compact, adjusting spacing and how wide Hal's replies run. (Comfortable is the default.)
- The defaults reproduce Hal's classic look, and the chat updates live as you change these. The system's own Dynamic Type accessibility setting still scales the text on top of your choice.

**Read-Aloud**
- **Read responses aloud**, **Voice**, and **Speaking Speed**, described above under Read-aloud.

**Import/Export**
- **Upload Document to Memory** and **Export Thread**.

**AI Model**
- The active model (or, in Salon Mode, the list of active seats) and **Browse Model Library**.

**Conversation Mode**
- The **Single LLM / Multi LLM (Salon)** switch, and a button into either **Single LLM Settings** or **Salon Mode Settings** depending on the mode.
- **Single LLM Settings** holds the memory and thinking tuning: **Memory Depth** (how many recent turns are kept verbatim), **Recency Weight** and **Memory Half-Life** (how Hal balances relevance against freshness when searching memory), **Max RAG Retrieval** (how much long-term memory a turn may pull), **Identity Half-Life** and **Identity Floor** (how long learned traits persist), and the **Thinking Cap**. Sliders show a marker when moved off the model's tuned default, and changing a setting is narrated back to you in the chat.

**The Lab**
- Hal's power-user tools (RoboRunner, the Developer API, and the `hal` CLI installer), described in their own sections below.

**Maintenance & Reset**
- **Settings Reset:** reset just the active model's settings to its tuned defaults, or reset every setting across every model to factory defaults (neither touches your conversations, documents, or Hal's learned self-knowledge).
- **Storage:** the model cache size, **Clear Hal's Models**, **Free up old model files** (a gentle, honest reclaim that never removes a file a sibling app still uses), and **Clear all family models** (a last-resort wipe of every shared model across the AI family).
- **Database:** your total thread and document counts, and **Nuclear Reset**, which deletes all conversations, summaries, documents, and memory. This cannot be undone.

**About Hal Universal**
- App identity and version, Hal's own license and source link, and every bundled open-source component with its license.

### The Lab (power users)

For advanced users and testing, Hal includes **The Lab**, reached from Settings. This is where Hal's transparency goes all the way down: you can watch and script what he does. The Lab holds:

- **RoboRunner:** an on-device automation script editor. You can write scripts, check them against a validator, and draft one from a plain-language description. Hal runs these entirely on the device.
- **Developer API:** an optional local HTTP server so other apps on your network can reach Hal. It is off by default; when on, it shows the address, port, and a token to copy.
- **Hal CLI (on Mac):** a one-line installer for a `hal` command you can run in your Mac Terminal, which talks to the app over that local API.

The Lab starts in **Safe mode**, which refuses destructive commands until you deliberately switch to **Advanced**. The first time you enter, a short "here be dragons" notice explains this. Most people never need the Lab; it lives out of the way in Settings.

### The signal cheat-sheet

| Signal | Where | Means |
|---|---|---|
| Stop circle, red | Reply footer | You stopped this reply; kept on screen, **not saved** |
| Scissors, red | Reply footer | Memory **truncated** (cut to fit) this turn; full memory still preserved |
| Compress bars, gray | Reply footer | Memory **condensed** (distilled to fit) this turn; normal and fine |
| Spinner + "Processing..." + timer | Reply footer (while generating) | Hal is producing this reply now; names the model at work |
| "Inference X.X sec" | Reply footer | How long a thinking turn took |
| "Seat N of M" / "Host" | Reply footer (Salon Mode) | Which voice, or the moderator, spoke |
| Brain | Top bar | Toggles **thinking mode** (bright on, dim off) |
| Life ring | Top bar | Opens **Help Mode** (bright when a topic is active) |
| Thermometer | Top bar | Device is **warm to hot**; Hal is pacing himself (hidden when cool) |
| Padlock | Top bar | **Privacy indicator**: closed = on-device, open = Apple Intelligence with network (cloud possible) |
| Paper-plane / stop circle | Composer | Send / stop generating |
| Model name | Reply footer | Which model produced this reply |

*When in doubt, ask Hal. That is what he is for.*

---

## RoboRunner

RoboRunner is a tiny automation language and runner that lives **inside Hal, on the device**. You hand it a script, a plain list of steps, and it runs that script autonomously on the device, one step at a time, capturing the results to a local file you can read back later.

It exists for **comparing models on the device itself**, and most pointedly for one comparison the network gets in the way of: how **Apple Foundation Models** answers when the device genuinely cannot reach the network (so nothing can quietly route to Private Cloud Compute), measured against the local **MLX** models. Hal can normally be driven remotely, one command per network round-trip (the Developer API). That is fine for single commands, but for a *sweep* (the same question put to several models, or one model at several temperatures) remote driving cannot do that comparison, for three reasons:

- for Apple Foundation Models it forces the network to stay on, so an answer might come from Private Cloud Compute rather than truly on-device,
- it keeps the device's composer busy with continuous remote-driven turns, and
- it cannot read the device's own thermal state.

RoboRunner moves the loop *onto* the device, which fixes all three. A script is handed over once; RoboRunner runs each real turn through Hal's live two-phase reasoning path and writes results to a local JSON file. Because it runs on-device it can also pace itself against the real thermal state and stamp each captured turn with the thermal reading before, during, and after; that is a useful byproduct when you are watching how models behave under load, but the point of the tool is the comparison itself: the same question, several models, one device, no network. Nothing streams per-turn over the network while it runs; the Developer API (or the in-app Run button) only *starts* it. You reach the editor from The Lab in Settings.

### The design posture

RoboRunner is deliberately **not** a general programming language. The grammar is tiny on purpose. Almost every line is just an existing Hal command verb passed straight through to the same dispatcher the Developer API uses, so verbs like `SWITCH_MODEL:`, `SET_REASONING:true`, `SET_REASON_BUDGET:80`, and `NEW_THREAD` all work with no extra code. Only a handful of constructs are special (`ASK`, `WAIT`, `FOR … END`, and `#` comments) because a flat verb model cannot express them. The one loop construct is condition-free: it repeats a written block over a written list. It cannot branch, and it cannot loop open-endedly. That keeps the Lab's "fixed verbs, not arbitrary code" posture.

### The script language

A script is a list of lines. Each line is one of:

| Line | Meaning |
|------|---------|
| `ASK <question>` | Run one real turn and capture it. |
| `WAIT <seconds>` | Pause (longer if the device is hot). |
| `FOR <VAR> IN a, b, c` … `END` | Repeat the enclosed block once per value, substituting `{{VAR}}`. |
| `# comment` | A comment line (ignored). |
| *anything else* | A raw command verb, e.g. `SWITCH_MODEL:<id>` or `SET_TEMPERATURE:0.7`. |

Lines are split on newlines and trimmed of surrounding whitespace; blank lines and lines beginning with `#` are dropped before execution. The special keywords (`ASK`, `WAIT`, `FOR`, `END`) are recognized case-insensitively.

**`ASK <question>` runs and captures one turn.** `ASK` is the heart of a script. It runs one real turn through Hal's live two-phase path and records a full result for it. Before starting, it cools down if the device is already hot, and it waits out any in-flight turn first (up to a cap). Each captured turn records the question, the thinking (phase-1) text, and the answer (phase-2) text with character counts; the model in force, the reason budget, and the reasoning-prompt override length; whole-turn wall time plus the phase-1 and phase-2 durations separately; and the thermal state *before* the turn, *at the phase boundary*, and *after*, so you can see *where* the heat enters (thinking versus answering). Results are written incrementally after each `ASK`, so a crash mid-run still keeps the turns captured so far.

**`WAIT <seconds>` paces between steps.** It sleeps in roughly one-second chunks so a stop request interrupts a long `WAIT` promptly. After the pause it will **not resume while the device is hot**: if the thermal state is serious or critical, it keeps waiting beyond the requested seconds until the device cools or a 5-minute safety cap is hit. A non-numeric or missing value parses as 0 seconds (no fixed pause, but the cool-down check still runs).

**`FOR <VAR> IN a, b, c` / `END` is the bounded sweep.** A `FOR … END` block repeats the lines between it once per value in the list, substituting the loop variable each pass. The header format is exactly `FOR <VAR> IN value1, value2, value3`. Values are split on commas and trimmed; empty values are dropped. Before running, the whole script is *expanded*: every `FOR` block is flattened into a plain step list with the placeholders already filled in, so the runner underneath just sees a longer flat list (and the `ASK` count shown in progress is already correct).

- **Nesting works.** An inner `FOR` expands once per outer value.
- **It is bounded.** There is a hard ceiling of **2000 expanded steps**. A sweep that would blow past it is truncated, and the validator flags it before you can run it.
- **A malformed `FOR` header** (no ` IN `, or an empty value list) is not silently swallowed; it surfaces as a problem and the validator reports it.
- A **stray `END`** with no matching `FOR` is ignored by the expander and flagged by the validator.

**`#` comments.** Any line whose first non-whitespace character is `#` is a comment and is ignored at run time. Blank lines are ignored too.

### Placeholders: `{{VAR}}` (doubled braces)

This is the most important rule to get right. Placeholders use **doubled braces**: `{{VAR}}`. A `FOR VAR IN …` block substitutes each value in place of `{{VAR}}` on every pass. The name match is case-insensitive.

**A single brace is *always* literal text.** One `{` or one `}` is never special; it is passed straight through to the model, untouched and unflagged. This is deliberate: prompts that naturally contain braces (JSON, code, shell snippets) stay deterministic and never trip the validator.

```
# Correct: a sweep placeholder is doubled.
FOR TEMP IN 0.2, 0.6, 1.0
    SET_TEMPERATURE:{{TEMP}}
    ASK In one short sentence, describe a city at night.
END
```

```
# Also fine: single braces are just literal prose passed to the model.
ASK Return this exactly as JSON: {"answer": 42}
```

A few exact-matching notes:

- Substitution matches `{{name}}` exactly, with the inner text taken verbatim (no trimming). So `{{ TEMP }}` reads as the name `" TEMP "` (with spaces) and will **not** match a `FOR TEMP`. Write `{{TEMP}}` with no inner spaces.
- The validator's brace scanner only counts doubled braces and stays in lockstep with the substitution logic, so what the coach flags and what actually substitutes can never disagree.
- Empty `{{}}` is ignored.

**A separate, unrelated single-brace feature.** One command, `SET_REASONING_PROMPT`, has its own `{question}` placeholder (single braces) that it fills with the current question during two-phase thinking. That is a feature of that verb, **not** a RoboRunner sweep placeholder. Do not confuse the two: a sweep variable is `{{VAR}}` (doubled); the reasoning-prompt's question slot is `{question}` (single).

### The validation "coach"

Every script is checked by a static, pure pre-flight validator, "the coach." It runs live in the editor as you type, on demand via the **Check** button, and again inside the runner as enforcement before a single verb executes. Because the editor and the runner use the *same* validator, what the editor shows and what the run refuses can never drift apart.

**One severity: "problem."** There is no error/warning split. Every issue is a single tier, a **"problem,"** and *any* problem blocks the run. In the editor, flagged lines get a **red** line number in the gutter and a faint red band behind them; the status strip reads "N problems, tap Check to see them"; the **Run** button is disabled while any problem exists; and the **Check** sheet lists every problem, each with its source line (or "Whole script" for issues with no single home).

What gets flagged:

- **Unknown verbs**, any line whose verb is not in the command catalog (and is not `ASK`/`WAIT`/`FOR`/`END`).
- **Malformed `FOR` header**, no ` IN ` or an empty value list.
- **Unbalanced `FOR`/`END`**, a `FOR` never closed, or an `END` with no matching `FOR`.
- **Undefined `{{VAR}}`**, a placeholder not defined by any enclosing `FOR`. (Single braces are never checked.)
- **Unknown model IDs**, a model argument to a model-taking verb that is not in the known set (the live catalog, the curated seeds present even before download, and Apple Foundation). This check runs on the *expanded* script, so a sweep like `FOR M IN afm, bogus` gets each resolved value checked. If the catalog is unavailable, model checks are skipped rather than producing false errors.
- **The expanded-step cap**, a sweep that expands past the 2000-step ceiling.

Model-ID and step-cap checks are reported as whole-script issues; structural, verb, and placeholder checks point at the exact original line number.

### How a script runs

1. **Pre-flight.** The runner validates the whole script first. If there is *any* problem, it refuses; nothing executes, and it returns a summary of the problems. This is what guarantees a typo'd verb, an unbalanced `FOR/END`, an unbound `{{VAR}}`, or a bogus model ID can never fire a real turn.
2. **Expand.** `FOR … END` blocks are flattened into a flat step list with placeholders filled in.
3. **Execute top to bottom.** For each step: `ASK` runs a captured turn (cooling first if hot, waiting out any in-flight turn), then persists results; `WAIT` paces (and holds longer if hot); anything else is dispatched through the shared command console, so the full verb vocabulary works. `SWITCH_MODEL:` is tracked so each captured result knows which model produced it.
4. **Between-step stop checks.** A stop request halts cleanly at the next step boundary and inside `WAIT`/cool-down pauses. It does *not* interrupt a turn mid-generation (that is the separate user Stop feature).
5. **Write results.** Each run writes one self-contained JSON file, `robo_results_<timestamp>.json`, in the app's Documents directory: the script, an ISO-8601 start time, and every captured turn, a lab-notebook page with input and output together. Each run gets its own file; later runs do not overwrite earlier ones.

Only one script runs at a time; a second start is refused while one is running.

**Stopping a run.** `ROBO_STOP` (or the Stop button that replaces Run while a script is running) requests a halt at the next between-step checkpoint. It is idempotent and keeps the partial results already captured. It never interrupts a turn that is mid-generation.

### The Library: examples and past runs

The editor's **Library** has two sections:

- **Your runs**, this device's run history, read from the `robo_results_*.json` files on disk, newest first. Each row shows a short title (the first captured question, else the file name), the turn count, and a date. Opening a run shows the script at the top and a card per captured turn (question, thinking, answer, and the timing/thermal metrics), with a toggle to the raw JSON and a **Share** button that hands the run's `.json` file to the share sheet.
- **Examples**, a small, progressive set of bundled, read-only example scripts (below). Each validates clean and runs in Safe mode.

Either kind can be **loaded into the editor**. Loading replaces the editor text but stashes what was there first, so a single **Undo** restores your previous work (the same "cannot eat your work" contract the wand and Clear use).

**Related editor tools.** **Commands** (Help) is a searchable, sectioned browser of every verb (verb, args, summary, a red badge for destructive verbs), plus a few multi-line **Templates** for structures people get wrong (a sweep, an ask, a model comparison); each row has a `+` to append it to the script. **Draft** (the wand) treats the editor's current text as a plain-language *description* and drafts a script from it in place, using Hal's own model plus the validator repair loop; if the field already holds a clean multi-step script, it asks before clobbering it, and the previous text is stashed for one-tap Undo. **Check** opens the coach's problem list without running.

### Driving RoboRunner over the Developer API

These verbs let a script or the test harness drive RoboRunner without a human tapping the screen. They share the one command catalog with the other two doors, so they also work from the `hal` CLI.

| Verb | What it does |
|------|--------------|
| `ROBO_RUN:<script>` | Start an on-device run. Returns immediately (`"started":true`); the run executes autonomously and paces against thermal state. **Destructive** (a script can issue any verb), so the safety gate applies. Refused if RoboRunner is already busy. |
| `ROBO_CHECK:<script>` | Validate a script **without running it**, the equivalent of Check. Returns `problemCount` and an `issues` array (each with `line` and `message`). Runs nothing. |
| `ROBO_GENERATE:<description>` | Draft a script from a natural-language description using Hal's model plus the validator repair loop. Returns `valid`, `attempts`, the `script`, and any remaining `issues`. Runs nothing. |
| `SET_ROBO_SCRIPT:<text>` | Set the editor's text (updates a live editor). Put a description here, then fire `ROBO_DRAFT_FROM_FIELD`. |
| `GET_ROBO_SCRIPT` | Read the editor's current text. |
| `ROBO_DRAFT_FROM_FIELD` | Fire the wand: draft a script *from* the current editor text and replace it in place. Errors if the editor is empty. |
| `ROBO_STATUS` | Report run status: `running`, `progress` (e.g. "3/18"), `resultsPath`, `error`. |
| `ROBO_RESULTS` | Return the captured results of the last run as JSON. |
| `ROBO_STOP` | Ask a running script to halt at the next step boundary; keeps partial results. |

**Safety gate.** `ROBO_RUN` is destructive because a script can issue *any* verb, including destructive ones. The Lab's process-wide safety mode (see [Safe and Advanced](#safe-and-advanced)) resets to Safe on launch, so driving a run over the API typically means `SET_SAFETY:advanced` first, then `ROBO_RUN:<script> CONFIRM` (or ` --yes`). Reset to Safe afterward.

**Operational note.** While a run is executing, the on-device antenna is busy, so `ROBO_STATUS` can time out. That is expected during a run: wait, do not poll-flood, and read `ROBO_RESULTS` once it frees up.

### Worked examples

These mirror the bundled example set exactly. Each validates clean and runs in Safe mode.

**1. Your first script.** The simplest script: one `ASK`. It runs a real turn and the answer is saved under "Your runs."

```
# Your first RoboRunner script.
# ASK runs one real turn; its answer is saved under Your runs.
ASK In one sentence, what makes a good cup of coffee?
```

**2. Take your time (a WAIT sequence).** Steps run top to bottom; `WAIT` pauses between them (longer automatically when the device is warm).

```
# Several steps in a row, with a pause between them.
ASK Name a color. One word.
WAIT 3
ASK Now name a fruit of that color. One word.
```

**3. Temperature spread (a `{{TEMP}}` sweep).** A sweep repeats the block once per value, filling in `{{TEMP}}` each pass. A higher temperature makes the answer more varied.

```
# {{TEMP}} is a placeholder the FOR fills in each pass.
FOR TEMP IN 0.2, 0.6, 1.0
    SET_TEMPERATURE:{{TEMP}}
    ASK In one short sentence, describe a city at night.
END
```

**4. Same question, different framing (system-prompt A/B).** The system prompt shapes *how* the model answers. Ask one question two ways and compare. Ends by clearing the override so normal chat resumes.

```
# Same question, two framings, side by side.
SET_SYSTEM_PROMPT:You are terse. Answer in one short sentence.
ASK What is the ocean?
SET_SYSTEM_PROMPT:You are a poet. Answer with a vivid metaphor.
ASK What is the ocean?
# Restore the default framing when done.
CLEAR_SYSTEM_PROMPT
```

**5. Compare models (a `{{MODEL}}` sweep).** Ask the same question to different models. Add another model id (from the Model Library) to the list to compare more.

```
# {{MODEL}} is filled in each pass. Add more ids to the list to compare.
FOR MODEL IN apple-foundation-models
    SWITCH_MODEL:{{MODEL}}
    ASK In one sentence, introduce yourself.
END
```

**6. Watch it think (two-phase reasoning).** Turn on two-phase thinking and customize the reasoning step. The reasoning prompt uses a single-brace `{question}` placeholder, a *different* thing than a sweep's `{{VAR}}`.

```
# Turn on two-phase thinking and customize the reasoning step.
SET_REASONING:true
SET_REASONING_PROMPT:Think step by step about {question}, then give a final answer.
ASK A train leaves at 2pm going 60mph. How far has it gone by 3:30pm?
```

### Quick reference

- **Special keywords:** `ASK`, `WAIT`, `FOR`, `END`, `#` (case-insensitive on the keywords).
- **Placeholders:** `{{VAR}}` (doubled braces), substituted by an enclosing `FOR`. A single brace is always literal.
- **Everything else** is a command verb passed straight through (browse them under Commands, or in the Command reference below).
- **Validation:** one severity ("problem"); any problem blocks the run. Same validator in the editor, on Check, and at run time.
- **Cap:** 2000 expanded steps.
- **Results:** one `robo_results_<timestamp>.json` per run in Documents; readable in the Library and via `ROBO_RESULTS`.

---

## Command API

The Command API is a **local, opt-in HTTP server** that lets another process drive Hal directly, bypassing the SwiftUI shell entirely, for automation and testing. Inside the app it is nicknamed "the antenna."

- It is a plain HTTP listener that Hal runs **on the device**.
- It is **off by default**. Nothing listens until you turn it on in the app.
- Every request is authenticated with a **bearer token**.
- It shares one command interpreter with RoboRunner and the `hal` CLI, so the verb vocabulary and the safety gate are identical across all three doors.

The API can change or delete real user data (there are destructive verbs). It is a developer and power-user tool. The Lab that hosts it warns "here be dragons" before you enter, and the API starts in **Safe mode**, which refuses destructive verbs until you deliberately switch to Advanced (see [Safe and Advanced](#safe-and-advanced)).

### Enabling the API and finding the address, port, and token

The toggle lives under **Settings, The Lab, Developer API, "Local API Access."**

1. Open **Settings, The Lab**. (The Lab shows a one-time "Here be dragons" acknowledgement before it opens.)
2. In the **Developer API** section, turn on **Local API Access**. This starts the listener.
3. Once enabled, three tap-to-copy rows appear:
   - **Address**, the device's local IPv4 address plus the port.
   - **Port**, which is **`8766`** for Hal. (Each app in the family uses its own port; Posey uses `8765`.)
   - **Token**, a 32-character lowercase hex string.

   Tap any row to copy its value.

A few more facts worth knowing:

- **Persistence is opt-in.** By default the API does **not** stay on across launches: it resets to off every time Hal starts, so you are never running a server you forgot about. If you want it to persist, turn on **"Keep on after I quit"** in the same Developer API section. That switch shows a one-time notice explaining the security tradeoff, and only after you consent does the API auto-start on future launches. Turn the switch off and you are back to the safe default.
- **Where the token comes from.** The token is stored in the device Keychain and created the first time you enable the API, so it is stable across launches and reinstalls until the Keychain item is removed.
- **Reachability.** The listener binds the port on all interfaces; use the device's Wi-Fi IP (the "Address" row). Reach the device over Wi-Fi, not USB, because a `.local` name can resolve to a temporary USB address.

The Mac-only **`hal` CLI** (its own section below) is just one client of this same HTTP API.

### The HTTP surface

All endpoints require the `Authorization: Bearer <token>` header. Routing is exact method and path; anything else returns `404`.

| Method | Path       | Body                          | Returns                              |
|--------|------------|-------------------------------|--------------------------------------|
| `POST` | `/chat`    | `{"message": "..."}`          | Full per-turn diagnostic JSON        |
| `POST` | `/command` | `{"command": "VERB:args"}`    | The verb's JSON result string        |
| `GET`  | `/state`   | (none)                        | A JSON snapshot of core runtime state |

Responses are always `Content-Type: application/json`, `Connection: close`.

**Authentication.** A missing or non-matching token returns **`401 Unauthorized`** (`{"error":"Unauthorized"}`). A malformed HTTP request returns **`400 Bad Request`**. If the app is not ready yet, endpoints return **`503`**.

**`POST /command`** is the main automation entry point. The body must be JSON with a non-empty `command` string:

```json
{"command": "SET_TEMPERATURE:0.7"}
```

The command is passed to the shared dispatcher (which runs the safety gate first, then the verb). The response is the verb's own JSON string, typically shaped like:

```json
{"status":"ok","temperature":0.7}
```

or, on error or safety refusal:

```json
{"status":"error","message":"SET_TEMPERATURE: must be 0.0-1.0"}
{"status":"error","blocked":"safety","message":"Safe mode: 'NUCLEAR_RESET' is destructive and is disabled. Switch to Advanced with SET_SAFETY:advanced to use it."}
```

Each verb's exact response fields vary; see the [Command reference](#command-reference) for what each does.

**`POST /chat`** sends a real user turn through Hal's live pipeline and returns a rich diagnostic record:

```json
{"message": "What is your name?"}
```

It waits out any in-flight turn (up to about 120 seconds; returns `503` `"Previous turn timed out"` if it cannot clear), then routes the message through Hal's normal send path (so the turn is cancellable via `STOP_GENERATION`). The response includes, among other fields:

```json
{
  "turn": 1,
  "timestamp": "2026-08-05T...",
  "thinkingDuration": 3.21,
  "model": "<model id>",
  "selfKnowledgeEnabled": true,
  "salonModeEnabled": false,
  "userMessage": "What is your name?",
  "response": "…Hal's answer…",
  "sectionsInjected": ["system", "self_knowledge", "user_message"],
  "tokenBreakdown": { "system": 0, "shortTerm": 0, "summary": 0, "rag": 0,
                      "userInput": 0, "completion": 0, "totalPrompt": 0,
                      "total": 0, "contextWindow": 0, "percentUsed": 0.0 },
  "memoryRetrieved": [ { "content": "…", "relevance": 0.812,
                         "source": "…", "isEntityMatch": false } ],
  "toolsUsed": [],
  "fullPrompt": "…the exact prompt string sent to the model…"
}
```

The token accounting is reconstructed from the same prompt the in-app Prompt Details view uses, so `/chat` and the UI cannot disagree.

**`GET /state`** returns a snapshot of Hal's core runtime state:

```json
{
  "modelID": "<live model id>",
  "conversationId": "…",
  "activeThreadMessages": 4,
  "turnCount": 2,
  "memoryDepth": 10,
  "maxMemoryDepth": 40,
  "temperature": 0.70,
  "reasoningCapTokens": 300,
  "selfKnowledgeEnabled": true,
  "recencyWeight": 0.30,
  "recencyHalfLifeDays": 7.0,
  "maxRagSnippetsCharacters": 4000,
  "ragDedupThreshold": 0.92,
  "lastSummarizedTurnCount": 0,
  "injectedSummaryActive": false,
  "injectedSummaryLength": 0,
  "totalConversations": 12,
  "totalTurns": 88,
  "totalDocuments": 3,
  "systemPromptOverrideActive": false,
  "systemPromptFingerprint": "You are Hal…..."
}
```

(The exact numbers are illustrative; the field set is from the code.)

### Concrete example (curl)

Assuming the Lab shows Address `192.168.1.50:8766` and your token:

```bash
IP=192.168.1.50
PORT=8766
TOKEN=<your-token>

# Read current state
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$IP:$PORT/state"

# Run a (non-destructive) command
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"CURRENT_MODEL"}' \
  "http://$IP:$PORT/command"

# Send a real chat turn
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello, Hal."}' \
  "http://$IP:$PORT/chat"
```

### The safety model

The safety layer is defined once in the command catalog and enforced at a single chokepoint, so **every** door (HTTP, the `hal` CLI, RoboRunner) inherits it. The mechanics are covered under [Safe and Advanced](#safe-and-advanced) above; the API-specific details:

- Each verb carries a `destructive` flag. When destructiveness was uncertain, the verb was marked destructive: over-gating costs one extra confirmation, under-gating risks data loss.
- **Safe mode (default)** refuses destructive verbs outright. **Advanced mode** allows them, but only if the command carries an explicit **confirm marker** as its last whitespace-separated token.
- The mode is process-wide and **resets to Safe on every launch**.
- The accepted markers, matched case-insensitively as the **last** token, are **`--yes`**, **`--force`**, and **`CONFIRM`**. Only the trailing token counts, so an argument that merely ends in "confirm" is never mistaken for approval. On allow, the marker is stripped before the verb parses its own arguments.

Switch modes with `{"command": "SET_SAFETY:advanced"}` (or `safe`). `SET_SAFETY` is itself non-destructive, so it always passes the gate.

**Running a destructive verb.** Take `DELETE_MODEL:<id>`. In Safe mode:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"command":"DELETE_MODEL:some-model-id"}' "http://$IP:$PORT/command"
# -> {"status":"error","blocked":"safety","message":"Safe mode: 'DELETE_MODEL' is destructive and is disabled. Switch to Advanced with SET_SAFETY:advanced to use it."}
```

Switch to Advanced, then confirm:

```bash
curl -s ... -d '{"command":"SET_SAFETY:advanced"}' "http://$IP:$PORT/command"

# Without the marker, Advanced still refuses:
curl -s ... -d '{"command":"DELETE_MODEL:some-model-id"}' "http://$IP:$PORT/command"
# -> {"status":"error", ... "Re-send with a trailing ' --yes' (or CONFIRM) to proceed."}

# With the marker as the last token, it runs:
curl -s ... -d '{"command":"DELETE_MODEL:some-model-id --yes"}' "http://$IP:$PORT/command"
```

Switch back to Safe (`SET_SAFETY:safe`) when you are done. Note that `ROBO_RUN` is itself destructive (a script can issue any verb), so starting a run requires Advanced mode plus a confirm marker, e.g. `{"command":"ROBO_RUN:<script> --yes"}`; destructive verbs *inside* a script are executed through the same gate.

### The verbs

Every verb is listed in the single [Command reference](#command-reference) below, generated from the app's catalog so it always matches the running build. You can also fetch the live, build-accurate list at runtime with `{"command":"HELP"}` (`HELP:SAFE` hides destructive verbs; `COMMANDS` is a synonym). If this document and the app ever disagree, the app is right.

A couple of honest notes about the sampling verbs. The catalog exposes `SET_TOP_P`, `SET_TOP_K`, `SET_PRESENCE_PENALTY`, and others, but on the local MLX path only **temperature** and **repetition penalty** are actually wired into generation today; the other sampling verbs set the stored setting without changing MLX output yet. Treat them as set-the-setting verbs whose runtime effect depends on the model path. And the debug-only verbs that exist in developer builds are compiled out or refused in the shipping App Store build, and are filtered from `HELP`, so treat them as unavailable to end users.

---

## Command line

`hal` is a small, self-described **thin client**. Its own description says it plainly:

> "This is a THIN client: it forwards your input to the running Hal app's local API (the antenna) over HTTP and prints what comes back. The app holds the brain; this is just a doorway."

Concretely, `hal` is a single Python 3 script (standard library only, no `pip` installs) that resolves a host, port, and token from config, POSTs your input to the running Hal app over HTTP, and prints the response. It does almost no logic of its own; all the intelligence lives in the app. It is one of the three doors into the same command interpreter as the Developer API and RoboRunner.

### How it relates to the Command API

`hal` speaks to the app's local HTTP server (the antenna), the same server the rest of the Lab tooling uses. It uses two of the server's three routes:

- **chat** goes to `POST /chat` with `{"message": "..."}`
- **command** goes to `POST /command` with `{"command": "..."}`

(For state, use the `GET_STATE` verb through a command.) The talk-versus-command split is deliberate and never guessed: **plain text is always chat; a leading `/` always marks a command.** The command surface is not defined by the CLI at all; it is whatever the app's command catalog publishes. The CLI just forwards the verb string.

### Setup

**1. Enable the API in the app.** The antenna is **off by default**. Turn it on inside the running Hal app under **Settings, The Lab, Developer API**. Nothing the CLI does works until the app is running with the API enabled.

**2. Install the `hal` command.** `hal` ships bundled inside the app, and it also lives in the open-source repo at `cli/hal` with an installer beside it. From a repo checkout, run the installer:

```bash
./cli/install-hal-cli.sh              # installs to ~/.local/bin
./cli/install-hal-cli.sh /usr/local/bin
```

It copies the `hal` script (which lives next to it at `cli/hal`) to the destination, marks it executable, and tells you whether the destination is on your `PATH` (adding, if needed):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**3. Configure host / port / token.** `hal` resolves `{host, port, token}` in this exact order:

1. **Environment variables:** `HAL_HOST`, `HAL_PORT`, `HAL_TOKEN`
2. **`~/.config/hal/config.json`**, of the form `{"host": ..., "port": ..., "token": ...}`
3. **Repo dev config**, resolved relative to the script (only meaningful when running from a checkout)
4. **Defaults:** host `127.0.0.1`, port `8766`

Environment variables win over files; the first config file that exists is used. **A token is always required**; there is no default token. Host and port fall back to the defaults if unset, but every command still needs a token from one of the first three sources. The token is minted and stored by the app (Keychain-backed, stable across launches) and shown in the running app's Lab settings. Requests send it as an HTTP header, `Authorization: Bearer <token>`.

Example `~/.config/hal/config.json`:

```json
{ "host": "192.168.1.50", "port": 8766, "token": "<your-token>" }
```

Example via environment:

```bash
export HAL_HOST=192.168.1.50
export HAL_PORT=8766
export HAL_TOKEN=<your-token>
```

### Usage

```
hal                      Interactive chat (a REPL). Plain lines are chat;
                         lines starting with '/' are commands.
hal <text...>            One-shot chat: send the text, print Hal's reply.
hal /VERB[:args]         One-shot command, e.g.  hal /SWITCH_MODEL:qwen3.5
hal help                 Show Hal's command catalog (the HELP verb).
hal --help | -h          Show THIS usage.
```

Note the two distinct "help"s: `hal --help` (or `-h`) prints the **CLI's own usage**, while `hal help` (or `hal commands`) fetches the **app's command catalog** live via the `HELP` verb.

**One-shot chat.**

```bash
hal "hi Hal, what model are you running?"
```

Sends `POST /chat`; prints Hal's `response` text. If the JSON response has no `response` field, `hal` prints the raw JSON rather than fabricate a reply.

**One-shot command.**

```bash
hal /CURRENT_MODEL
hal /SWITCH_MODEL:qwen3.5
```

Sends `POST /command`; prints the pretty-printed JSON result. Everything after the leading `/` (joined across arguments) is the verb string, forwarded verbatim.

**Interactive REPL.** Running `hal` with no arguments in a terminal starts a REPL:

```
$ hal
Hal interactive. Type to chat. '/VERB' runs a command, '/help' lists them, '/quit' or Ctrl-D exits.
hal> what did we talk about yesterday?
  ...Hal's reply...
hal> /CURRENT_MODEL
{ ...json... }
hal> /quit
```

Plain lines are chat (printed indented); `/VERB` is a command; `/help` or `/commands` shows the catalog; `/quit`, `/exit`, `/q`, or Ctrl-D exits.

**Piping (stdin).** If stdin is not a terminal, `hal` reads it:

```bash
cat notes.txt | hal "summarize this"      # stdin appended to the message
hal /GET_STATE | jq .                       # command output is plain JSON
```

`hal "msg"` with piped stdin sends `"msg\n\n<stdin>"`; `hal` with no args and piped stdin sends the piped text as a one-shot chat (no REPL, because stdin is not a terminal); command output is plain JSON, so it pipes cleanly into `jq`.

**Destructive commands and safety confirmation.** Some catalog verbs are marked destructive, and the app's safety layer can block them. In the **interactive REPL**, if the safety layer blocks a confirmable command, `hal` shows the reason and prompts `Are you sure? [y/N]`; on `y`/`yes` it re-sends the same verb with ` --yes` appended. In **one-shot mode** there is no prompt: you append the confirmation marker yourself, e.g. `hal "/DELETE_MODEL:<id> --yes"`. Whether a destructive command is even offered depends on the app's safety mode (`SET_SAFETY:safe` versus `advanced`), enforced server-side, not by the CLI.

### Command surface

**The CLI does not define any commands.** It forwards whatever verb string you give it. The authoritative list is the app's command catalog, surfaced live by the `HELP` verb:

```bash
hal help
```

`hal` pretty-prints the catalog grouped by category, with a `[!]` marking destructive verbs. This is the same catalog that feeds the RoboRunner editor's Help and Hal's own self-knowledge, so it is always in sync with the running build. The full list is in the [Command reference](#command-reference) below; the 15 categories are Models & Downloads, Threads & Messages, System Prompt, Sampling & Generation, Thinking, Memory & Retrieval, Embeddings & Database, Thermal, Salon Mode, Self-Knowledge & Reflection, Documents, UI & Display, RoboRunner Automation, State & Logs, and Resets & Test Fixtures. Because the surface is defined by the app, verbs can appear or disappear per build (some are debug-only and hidden in Release); treat `hal help` against your running build as the source of truth.

### Troubleshooting

- **"No API token found."** You have host and port but no token. Set `HAL_TOKEN`, or add a `token` to `~/.config/hal/config.json`. The token is shown in the running app's Lab settings.
- **"Cannot reach Hal at http://host:port/ ..."** The app is not running, the API is off, or the host/port is wrong. The API is off by default; enable it in the app's Lab settings. Confirm host and port match the running app (default port `8766`).
- **`{"error":"Previous turn timed out"}` (HTTP 503).** A `/chat` call arrived while the app was already responding; the server waits up to about 120 seconds for the prior turn before giving up. Retry once the app is idle.
- **Response is raw JSON instead of a clean reply.** The `/chat` result lacked a `response` field, so `hal` printed what it actually received rather than invent a reply. Inspect the JSON for an `error` or unexpected shape.

### Quick reference

```bash
# setup
./cli/install-hal-cli.sh          # installs hal to ~/.local/bin
export HAL_HOST=<ip> HAL_PORT=8766 HAL_TOKEN=<token>

# chat
hal "hello Hal"
echo "long text" | hal "summarize"

# commands
hal help                     # the app's command catalog
hal /CURRENT_MODEL
hal /GET_STATE | jq .
hal                          # interactive REPL
```

---

## Command reference

The same verbs work through the Developer API, RoboRunner, and the `hal` command line. This list is generated from the app's command catalog.

<!-- BEGIN GENERATED COMMAND REFERENCE. Do not edit by hand.
     Regenerate with scripts/sync_command_reference.sh (reads CommandCatalog.all). -->

*113 commands. Generated from the app's command catalog, so this list always matches the running interpreter. The same verbs work through all three doors (Developer API, RoboRunner, hal CLI). Commands marked **[Advanced]** change or delete data and are refused in Safe mode; switch to Advanced and add a trailing `--yes` (or `CONFIRM`) to run them.*

### Models & Downloads

| Command | What it does |
|---|---|
| `CANCEL_DOWNLOAD:<modelID>` | Cancel an in-flight model download. |
| `CURRENT_MODEL` | Report the active model id and display name. |
| `DELETE_MODEL:<modelID>` **[Advanced]** | Delete a model's files. Releases this app's claim, files are removed only when no app still claims them. |
| `DOWNLOAD_MODEL:<modelID>` | Start downloading a catalog model into the shared store. |
| `LEGACY_MIGRATION:<subcommand>` **[Advanced]** | Drive or inspect the legacy model-storage migration. Advanced, touches model files. |
| `LIST_MODELS` | List catalog models and their download state. |
| `MLX_STATE` | Diagnostic snapshot of the MLX runtime and catalog for the selected model. |
| `MODEL_STATUS:<modelID>` | Report download and disk status for one model. |
| `SET_MODEL:<modelID>` | Alias of SWITCH_MODEL: set the active chat model. |
| `SHARED_MODELS` | Report the App-Group shared model store: which models are present and which apps claim each. |
| `SWITCH_MODEL:<modelID>` | Switch the active chat model. |

### Threads & Messages

| Command | What it does |
|---|---|
| `EXPORT_THREAD` | Export the current thread as text. |
| `GET_MESSAGES` | Return the current thread's messages, full content. Add :preview for a 500-char cap. |
| `GET_RENDERED_MESSAGES` | Return the in-memory chat messages as shown, full content. Add :preview for a 500-char cap. |
| `GET_RENDERED_MESSAGES_FULL` | Alias of GET_RENDERED_MESSAGES (kept for older scripts); full content. |
| `GET_THREADS` | List conversation threads. |
| `NEW_THREAD` | Start a new conversation thread. |
| `RESET_THREAD` **[Advanced]** | Reset the current thread, clearing the active conversation. |
| `STOP_GENERATION` | Stop the in-flight chat generation (the user STOP button). Keeps the partial answer, reverts to send. |
| `SWITCH_THREAD:<threadID>` | Switch to an existing conversation thread. |

### System Prompt

| Command | What it does |
|---|---|
| `CLEAR_SYSTEM_PROMPT` | Clear the system-prompt override and restore the default. |
| `SET_SYSTEM_PROMPT:<text>` | Override the system prompt for this session. |
| `SET_SYSTEM_PROMPT_STORED:<text>` | Set and persist the stored system prompt. |

### Sampling & Generation

| Command | What it does |
|---|---|
| `RESET_MODEL_SETTINGS` **[Advanced]** | Reset the current model's settings to defaults. |
| `SET_MAX_OUTPUT_TOKENS:<int>` | Cap output tokens. Also bounds the phase-1 thinking pass. |
| `SET_PRESENCE_PENALTY:<value>` | Set the presence penalty. |
| `SET_REPETITION_PENALTY:<value>` | Set the repetition penalty. |
| `SET_TEMPERATURE:<0.0-1.0>` | Set the model's sampling temperature. |
| `SET_TOP_K:<int>` | Set top-k sampling. |
| `SET_TOP_P:<0.0-1.0>` | Set nucleus sampling top-p. |

### Thinking

| Command | What it does |
|---|---|
| `GET_THINK_STREAM` | Return the latest thinking-phase stream. |
| `SET_REASONING:<true|false>` | Toggle two-phase thinking (watch Hal think). |
| `SET_REASONING_PROMPT:<text>` | Override the phase-1 REASON instruction. Supports a {question} placeholder. |
| `SET_REASONING_TEMP:<value>` | Set the temperature used during the thinking phase. |
| `SET_REASON_BUDGET:<int>` | Override the phase-1 thinking token budget. |
| `SET_THINKING_CAP:<100-500>` | Set the per-model Thinking Cap, the phase-1 reason token ceiling. |

### Memory & Retrieval

| Command | What it does |
|---|---|
| `CLEAR_QUERY_EXPANSION_CACHE` | Clear the query-expansion cache. |
| `GET_MEMORY_STATS` | Report memory store statistics. |
| `MEMORY_DUMP:<query>` | Dump memory rows matching a query, for diagnostics. |
| `MEMORY_SEARCH_DEBUG:<query>` | Run a memory search with debug scoring output. |
| `MEMORY_SEARCH_EXPANDED:<query>` | Run a memory search with query expansion and debug output. |
| `MEMORY_SIMILARITY_DEBUG:<args>` | Report similarity scoring between memory items, for diagnostics. |
| `QUERY_EXPANSION_CACHE_STATUS` | Report query-expansion cache status. |
| `RRF_STATUS` | Report the current RRF fusion parameters. |
| `SET_FORCE_EXPANSION:<true|false>` | Force query expansion on or off, for testing. |
| `SET_MAX_RAG_CHARS:<int>` | Cap the characters of retrieved memory injected into the prompt. |
| `SET_MEMORY_DEPTH:<int>` | Set how many prior turns are kept in working memory. |
| `SET_MEMORY_ISOLATION:<true|false>` | Toggle memory isolation, for testing. |
| `SET_RAG_DEDUP:<value>` | Set the retrieval dedup similarity threshold. |
| `SET_RECENCY_HALFLIFE:<days>` | Set the recency half-life in days for retrieval. |
| `SET_RECENCY_WEIGHT:<value>` | Set the recency weighting in retrieval. |
| `SET_RRF_BM25_DEFAULT_K:<int>` | Set the RRF k for the BM25 default arm. |
| `SET_RRF_BM25_DISTINCTIVE_K:<int>` | Set the RRF k for the BM25 distinctive arm. |
| `SET_RRF_SEMANTIC_K:<int>` | Set the RRF k for the semantic retrieval arm. |

### Embeddings & Database

| Command | What it does |
|---|---|
| `BACKFILL_EMBEDDINGS:[:<args>]` **[Advanced]** | Backfill missing embeddings across the store. Heavy, rewrites database rows. |
| `DB_SCHEMA:<table>` | Report the schema of a database table. |
| `DOWNLOAD_EMBEDDING_MODEL:[:<id>]` | Download an embedder model. |
| `EMBEDDING_COVERAGE` | Report embedding coverage across the memory store. |
| `EMBEDDING_DOWNLOAD_STATUS:[:<id>]` | Report embedder download status. |
| `EMBEDDING_STATUS` | Report the active embedder and its load state. |
| `EMBED_PROBE:<text>` | Probe the embedder on a string, for diagnostics. |
| `EMBED_SIM:<args>` | Compute embedding similarity between two strings. |
| `EMBED_SIM_BATCH:<args>` | Batch embedding-similarity computation, for testing. |
| `FTS_DIAG` | Diagnostic for the full-text search index. |
| `MIGRATE_EMBEDDINGS_REEMBED` **[Advanced]** | Re-embed the store under the current embedder. Heavy, rewrites database rows. |
| `SET_EMBEDDING_BACKEND:<backend>` | Switch the embedding backend. |

### Thermal

| Command | What it does |
|---|---|
| `GET_THERMAL_STATE` | Report the current thermal level and governor state. |
| `SET_THERMAL_PACING:<value>` | Set the thermal governor pacing. |

### Salon Mode

| Command | What it does |
|---|---|
| `SALON_GET_STATE` | Report the salon configuration and seats. |
| `SALON_SET_ENABLED:<true|false>` | Enable or disable Salon Mode. |
| `SALON_SET_MODE:<mode>` | Set the salon behavioral mode, independent or context-aware. |
| `SALON_SET_SEAT:<seat:model>` | Assign a model to a salon seat. |
| `SALON_SET_SUMMARIZER:<value>` | Configure the salon summarizer seat. |

### Self-Knowledge & Reflection

| Command | What it does |
|---|---|
| `FORCE_REFLECTION:<args>` | Force Hal to generate a reflection now. |
| `GET_REFLECTIONS` | Return Hal's stored reflections. |
| `RESET_SELF_KNOWLEDGE` **[Advanced]** | Reset and re-seed Hal's self-knowledge database. |
| `SELF_KNOWLEDGE_AUDIT:[:<args>]` | Audit the self-knowledge database contents. |
| `SET_SELF_KNOWLEDGE:<true|false>` | Toggle self-knowledge injection into the prompt. |

### Documents

| Command | What it does |
|---|---|
| `DELETE_DOCUMENT:<docID>` **[Advanced]** | Delete an imported document. |
| `IMPORT_DOCUMENT:<path|text>` | Import a document into Hal's reference store. |
| `LIST_DOCUMENTS` | List imported documents. |

### UI & Display

| Command | What it does |
|---|---|
| `GET_UI_STATE` | Report the current UI and navigation state. |
| `SCREENSHOT` | Capture the current key window as a PNG. View render only, does not show live camera or video. |
| `SCROLL:<down|up|top|bottom|pagedown|pageup>` | Scroll the frontmost scroll view (general parity with a human swipe on any scrollable screen). |
| `SET_TTS_AUTO_READ:<1|0>` | Turn auto-read on/off (read every completed response aloud). |
| `SET_TTS_RATE:<0.0-1.0>` | Set the read-aloud speaking rate (default 0.5). |
| `SET_TTS_VOICE:<identifier?>` | Choose the read-aloud voice by identifier (from TTS_VOICE_LIST); empty means Automatic. |
| `SET_UI_STATE:<state>` | Drive the UI to a semantic state, for example open settings or the model library. |
| `TAP:<x>,<y>` | Activate the most specific element at a screen point (points, matching UI_TREE and SCREENSHOT coordinates). |
| `TAP_LABEL:<label>` | Activate the visible element whose accessibility label matches (general tap-by-name; works on SwiftUI controls). A fallback for when no bespoke verb exists. |
| `TTS_PREFS` | Read back the read-aloud prefs (auto-read, stored voice/rate) plus the voice/rate speak() would actually use. |
| `TTS_SPEAK:<text?>` | Read text aloud (or the last Hal turn if no text). Strips markdown first. |
| `TTS_STATE` | Report read-aloud state (isSpeaking + message id). |
| `TTS_STOP` | Stop read-aloud. |
| `TTS_VOICES` | Report the read-aloud voice that would be used (name + quality) and how many premium/enhanced voices are installed. |
| `TTS_VOICE_LIST` | List installed voices for the current language (name, identifier, quality) so a specific voice can be chosen. |
| `UI_TREE:<controls?>` | List on-screen accessibility elements (role, label, id, frame in points): the general 'what's on screen' read. Add :controls for interactive elements only. |

### RoboRunner Automation

| Command | What it does |
|---|---|
| `GET_ROBO_SCRIPT` | Read the RoboRunner editor's current text. |
| `ROBO_CHECK:<script>` | Validate a RoboRunner script WITHOUT running it (the coach): returns errors + warnings with line numbers. Runs nothing. |
| `ROBO_DRAFT_FROM_FIELD` | Fire the editor's wand: draft a script FROM the current editor text and replace it in place (the wand action, drivable without a button tap). |
| `ROBO_GENERATE:<description>` | Draft a RoboRunner script from a natural-language description (Hal's model + the validator repair loop). Returns a validated script; runs nothing. |
| `ROBO_RESULTS` | Return the captured results of the last RoboRunner run. |
| `ROBO_RUN:<script>` **[Advanced]** | Run an on-device RoboRunner script. Advanced, a script can issue any verb, including destructive ones. |
| `ROBO_STATUS` | Report RoboRunner run status. |
| `ROBO_STOP` | Ask a running RoboRunner script to halt at the next step boundary. Keeps the partial results already captured. |
| `SET_ROBO_SCRIPT:<text>` | Set the RoboRunner editor's text (updates a live editor). Put a description here, then ROBO_DRAFT_FROM_FIELD. |

### State & Logs

| Command | What it does |
|---|---|
| `CLEAR_LOGS` | Clear the in-memory runtime log buffer. |
| `GET_LOGS:[:<n>]` | Return the last n runtime log lines, default 200. |
| `GET_STATE` | Return a JSON snapshot of Hal's core runtime state. |
| `SET_SAFETY:<safe|advanced>` | Set the Lab safety mode. Safe (default) refuses destructive verbs; Advanced allows them with a per-command confirmation (append --yes or CONFIRM). |

### Resets & Test Fixtures

| Command | What it does |
|---|---|
| `NUCLEAR_RESET` **[Advanced]** | Wipe all state (memory, settings, self-knowledge) back to first-run. |
| `RESET_HARDWARE_DISCLOSURE` | Reset the hardware-disclosure flag so it shows again. |
| `RESET_SETTINGS` **[Advanced]** | Reset all app settings to defaults. |

<!-- END GENERATED COMMAND REFERENCE -->

---

## Architecture

This is how Hal actually works under the hood: memory, embeddings, models, prompt construction, two-phase thinking, and thermal pacing. Where the code carries a caveat, or where something is an aspiration rather than a shipped fact, this section says so rather than smoothing it over, in the spirit of Hal's own commitment to honesty over confident overstatement.

### Memory

Hal's memory is a single SQLite database. The central table, `unified_content`, holds every conversation turn, imported document chunk, and piece of ingested source code as a row, tagged with a `source_type` (conversation, document, webpage, email, source code, and the self-knowledge piles). Each row carries its text, timestamps, turn and position bookkeeping, extracted entity keywords, and one embedding vector per embedding backend. There is no separate "vector database"; retrieval runs directly over `unified_content` and a companion FTS5 full-text index.

**Short-term versus long-term memory** are not two separate stores. They are two different *ways the same rows enter a prompt*:

- **Short-term memory** is the most recent conversation turns, replayed **verbatim** as alternating user and assistant messages. Depth is a per-model setting (for example three turns on Apple Intelligence, because its context window is tiny).
- **Long-term memory** is everything in `unified_content` reached by *search* (RAG retrieval): older turns from the current conversation, turns from other conversations, and imported documents. The verbatim short-term turns are explicitly **excluded** from the search, so the same turn is never both replayed verbatim and retrieved as a "memory."

A turn starts life as short-term (replayed exactly), and as it ages out of the verbatim window it becomes long-term (findable only by retrieval). Cross-session recall works because search is not scoped to the current conversation.

**How retrieval ranks results (hybrid search plus RRF).** Retrieval is a **hybrid** of two independent retrievers whose results are combined by **Reciprocal Rank Fusion (RRF)**:

1. **Semantic arm.** The query is embedded with the active embedding backend, then compared by cosine similarity against every stored row's vector in that backend's column. No similarity threshold is applied; every positive-similarity row is a candidate. Candidates are sorted, each gets a rank, and the list is capped at 50.
2. **BM25 (keyword) arm.** The query is sanitized into an FTS5 match expression and run against the full-text index, ordered by BM25 score, capped at 50. Entity keywords stored on each row feed this index, so named entities are lexically findable.

For each row, RRF sums `1 / (k + rank)` across whichever arms ranked it, so rows that rank well in *both* arms win. The `k` constants are live-tunable (roughly `kSemantic ≈ 15`, `kBM25 ≈ 60`). RRF combines by **rank, not raw score**, which sidesteps the problem that semantic cosine and BM25 scores live on totally different scales.

Two refinements sit on top of plain RRF:

- **BM25 quality gate.** BM25 can return confident-but-wrong hits when a query is dominated by common words (a "what car do I have?" matching an unrelated turn that shares "have"/"do"). The gate compares BM25's top hits against the semantic ranking, and if the two retrievers broadly disagree, BM25's contribution is dropped as noise. The gate is itself gated: it only applies when the embedder is confident, and it is **bypassed** when BM25 has a strong distinctive top hit (a rare or unique term, like an imported document's unique vocabulary, that semantic embedding may not understand). When BM25 is distinctive, it also gets a smaller `k` so its top rank dominates fusion.
- **Recency blend.** If recency weight is above zero, each RRF score is multiplied by a half-life decay factor. At weight zero this is an exact no-op (pure rank fusion); higher values nudge more-recent memories up without hard-sorting by time.

Fused results are capped by **both** a snippet count and a token budget, and each surviving snippet is prefixed with a human-readable age label (for example `[2 days ago]:`).

**Degradation is designed in.** If the embedding backend is not loaded (first-launch asset download pending, or a load failure), the semantic arm is simply skipped and BM25 carries retrieval alone. Retrieval quality drops but lexically distinctive terms still surface.

**Query expansion (weak-retrieval recovery).** Hybrid search fails when a query shares *neither* content words *nor* enough semantic proximity with the stored memory ("Where do I live now?" against "house in Berkeley"). When the first pass comes back weak, Hal asks the *active model* to extract five to ten related concept terms, then re-runs **only the BM25 arm** with the original tokens ORed with the expansion tokens. The semantic arm is unchanged (embeddings do not benefit from word expansion). Results are cached, keyed by a hash of the normalized query plus the model id, and the cache is cleared on model switch. The whole expansion prompt and response stay under about 200 tokens, so it is safe even on Apple Intelligence's 4K window.

**Entity extraction and the "knowledge graph."** On every stored turn, Apple's `NLTagger` runs over both the user and assistant text, pulling out people, places, and organizations. These are lowercased and stored as an entity-keyword string on the row, feeding the full-text index. To be honest about scope: what exists today is *entity-keyword tagging that strengthens lexical retrieval*, not a traversable graph of typed nodes and edges. The project's broader "knowledge graph" language describes an aspiration and the accumulating entity data that could support one; the retrieval path as written uses entities as keyword signal, not as graph structure.

**How memory gets into the prompt, and the honesty rule.** Retrieved long-term snippets are folded into the system message's context block. Whether a search even runs is decided per turn by a lightweight tool gate. Critically, the memory section **always tells the truth about itself**:

- If a search ran and found matches, the snippets are injected.
- If a search ran and found nothing, a note is injected telling Hal that an empty search is not the same as ignorance (answer general knowledge normally; only claim "not stored" for genuinely personal misses; never invent specifics).
- If no search ran this turn, a note is injected stating plainly that memory was **not** searched, so Hal does not narrate a retrieval that never happened.

These provenance notes are a direct expression of Maxim #1 (honesty and uncertainty) and Maxim #2 (access to reflection) living inside the retrieval path.

### Embeddings

Embeddings are produced by a single switchable provider wrapping whichever backend is active (chosen via a UserDefaults key, default Apple NLContextual).

| Backend | Dimension | Model | On-disk |
|---|---|---|---|
| Apple NLContextual | 512 | `NLContextualEmbedding` (built-in, Neural Engine) | none (lazy OS asset) |
| Nomic Embed Text v1.5 | 768 | `nomic-ai/nomic-embed-text-v1.5` | ~522 MB |
| Mixedbread mxbai-embed-large | 1024 | `mixedbread-ai/mxbai-embed-large-v1` | ~670 MB |

A fourth backend, **EmbeddingGemma**, is present in the code but **fully disabled** because of an upstream MLX iOS Metal-initializer crash on first load. Its enum case, switch arms, and load path are all commented, with a documented re-enable recipe; it is not selectable today.

**How text is embedded.** NLContextual embeds on-device with no download, mean-pools per-token vectors into one 512-dimension sentence vector, and ignores retrieval purpose. It has a first-install subtlety: after the OS provisions the asset, the requesting instance often cannot compute until relaunch, so the loader recreates a fresh instance and runs a **warm-up probe**; if the probe produces no vector, it refuses to cache the model and lets that session fall back to keyword-only retrieval (self-healing next launch) rather than silently emitting empty embeddings. Nomic is retrieval-asymmetric: it requires task-instruction prefixes for stored text versus queries, mean-pools, and L2-normalizes. mxbai is also asymmetric but prefixes only the query side, uses the CLS-token output, and L2-normalizes; its encodes are serialized on a dedicated queue because the underlying graph specialization is not concurrency-safe.

**How embeddings are stored (keep-both columns).** `unified_content` has **one permanent column per backend**. At write time the vector from the *active* backend is written to *its* column. Switching backends therefore does **not** wipe and re-embed; the retriever just reads a different column. An inactive backend's column is filled lazily in the background by a backfill worker; rows whose active column is still empty simply do not contribute a semantic candidate (BM25 carries them until backfill completes). Cosine similarity rejects dimension mismatches (returns 0) so a half-migrated database cannot silently produce noise.

Backend choice is a real tradeoff: NLContextual is instant, free, and private but least precise; Nomic is a balanced step up in precision; mxbai has the most detailed vectors but the largest download and slowest indexing. Measured retrieval separation (related versus unrelated) is roughly mxbai (0.48) > Nomic (0.30) > NLContextual (0.10). Similarity thresholds for reflection synthesis and trait evolution are **calibrated per backend**, because score distributions differ so much between models that a threshold tuned for one misbehaves on another.

### Models

Hal runs on **two runtimes**:

- **Apple Foundation Models** (Apple Intelligence), the on-device system model reached via `LanguageModelSession`. Always present, no download, but a small **4,096-token** context window. Because iOS 26 only ships on hardware capable of Apple Foundation Models, this model is guaranteed available on any device that can run Hal.
- **MLX local inference**, quantized community models (typically `mlx-community/...-4bit`) run fully on-device.

**The catalog and curated seeds.** A catalog service holds the model list, bound across the UI. Alongside Apple Intelligence it seeds a **curated tier** of MLX models that have been personally validated with Hal's pipeline (a confirmed 4-bit build, a chat template that loads, EOS tokens registered, and testing in single-model and Salon Mode). Each carries its context window, size, license, per-model tuned defaults, an optional framing prompt, and a per-Maxim scorecard. Curated models in the source include Gemma 4 E2B (128K context, 3.58 GB), Phi-4 Mini (128K), Qwen 3.5 2B (262K), Llama 3.2 3B (128K), Dolphin 3.0 (128K), and Ternary Bonsai 8B (65K). Beyond the seeds, the catalog can fetch the broader `mlx-community` list from Hugging Face and detect each model's context window with a three-tier fallback: `config.json`, then a name heuristic, then a safe 4K default.

**Downloading.** Downloads use a **background URL session** so they continue while the app is suspended or terminated; iOS delivers completion to the app, which reconnects to the in-flight session. The downloader fetches a model's file list, filters to MLX-compatible files, enqueues one task per file, persists per-task metadata so post-relaunch callbacks route correctly, does disk-space pre-flight, and runs one active download at a time.

**Sharing models across the app family.** Downloads land in an **App-Group shared store**, not per-app caches, so sibling apps (Posey, Thomas: AI Camera) reuse the same on-disk model. The store is **reference-counted**: apps claim a model on successful load so a sibling's cleanup pass will not delete a model still in use. Version-pinned curated models get a commit-specific folder so a specific commit is never confused with another.

**Loading and unloading.** Loading a large MLX model is asynchronous (roughly 5 to 15 seconds). Two runtime realities are handled explicitly: Hal **unloads** the resident MLX model when it enters the background so iOS does not jetsam it (a message typed after returning triggers **reload-on-demand**), and a turn arriving mid-switch **waits** for the in-flight load before generating. If a model still is not resident after awaiting and reloading, a real error surfaces rather than a silent failure.

### Prompt construction and budgeting

The prompt is assembled into a list of chat messages (system, user, assistant), the chat-template form that modern models understand natively.

**The context-window budget.** Each model's context window is divided into fixed percentage allocations that sum to **97%**, leaving a 3% safety buffer (a build-time assertion enforces under 100%, added after an earlier over-allocation caused real context overflows):

| Segment | Allocation |
|---|---|
| Prompt (system + framing + self-knowledge + temporal) | 50% |
| Response reserve | 20% |
| RAG retrieval | 15% |
| Short-term history | 12% |

For Apple Intelligence's 4,096 tokens that works out to roughly prompt 2,048, response 820, RAG 614, short-term 491. For a 128K model everything scales up proportionally. Two **hard caps** are fixed across all models because they reflect authoring limits, not model capacity: the user-editable system prompt (1,000 tokens, rejected at the UI if exceeded) and the per-model framing prompt (400 tokens).

**Assembly, segment by segment.** The system message is the effective system prompt (persona plus optional framing) followed by a context block built from these sections, in order:

1. **Temporal context**, date, time of day, weekday, session and uptime signals. Tiny, never compressed.
2. **Conversation summary**, an LLM summary of older history, injected only when older turns have been compressed.
3. **Self-awareness**, a small runtime-stats block (turn count, uptime). Injected on every model, including Apple Intelligence.
4. **Self-knowledge**, the persistent identity and traits corpus. Injected **raw, never compressed** (compression is treated as unacceptable for identity content), and **not injected at all on Apple Intelligence**, whose 4K window cannot host the corpus and where lossy compression is refused by design.
5. **RAG retrieval**, long-term memory snippets when a search ran (or a truthful "found nothing" / "did not search" provenance note otherwise).

Then conversation **history** is appended as alternating user and assistant turns, with partials and user-stopped turns filtered out entirely, and finally the current user message.

**Per-segment pre-flight and compression.** Within the 50% prompt allocation, static caps are subtracted first and the remaining "dynamic room" is split (summary gets about 30%, self-knowledge the rest, each with a floor). Every dynamic segment is then run through a pre-flight check: if it fits, it passes unchanged; if it is over budget and *compressible*, it is compressed by **the active model itself** (never a different model). The summarizer includes a sentence-level veracity check (ungrounded sentences are replaced with the nearest source sentence) so Hal gets a *verified distillation of his own content*, not a model's invention. Compressions are cached so repeated turns do not redo the work.

Compression is never silent trimming. When intelligent compression fails (empty output, big overshoot, or an internal fallback), the segment is raw-truncated and flagged as truncated, which drives the visually distinct "truncated" (scissors) badge in the UI footer versus the "condensed" badge, so the user can always see when their content was lopped rather than summarized. Self-knowledge and reference/code material are exempt from model compression: self-knowledge is injected raw, and code material is head-truncated verbatim to keep it exact.

**Self-reference and Help Mode.** There is a separate path for questions about Hal's own code or tooling. When a turn is judged self-referential (or the user explicitly enters Help Mode), the personal-memory RAG is skipped and its budget is redirected to a BM25 search over Hal's own ingested source code and tool docs, which are otherwise excluded from general RAG (the "one door" rule). This is the fix for Hal confabulating his own architecture instead of reading it (Maxim #2), and it comes with a private honesty directive telling Hal to distinguish confidence from inference and never invent commands or code.

### Two-phase thinking

When the "brain" (reasoning) toggle is on, a turn runs as **two model passes** instead of one, and it is **model-agnostic**: it works on every model, not just ones with native think tokens. Brain off is a single normal pass.

**Phase 1, REASON.** Hal builds the *full* context (all the sections above) around a REASON instruction, by default *"Work through this carefully, step by step, showing your full reasoning as you go. Do not state a final answer yet."* This pass streams live into the collapsible thinking panel and is **bounded to a depth budget** (a per-model user setting via the Thinking slider, default 300 tokens, range 100 to 500). Bounding the reason pass keeps a runaway from overheating the device or blowing the phase-2 budget; only this pass is capped, so real answers are never clipped. The captured reasoning is then trimmed on a sentence or line boundary to the budget.

**Phase 2, CONCLUDE.** A fresh, minimal message set is sent: just the clean persona plus a CONCLUDE prompt containing the original question and the bounded phase-1 reasoning, marked as *private thoughts the user cannot see and Hal must not quote or describe*. Hal answers directly, in his own voice. Notably, **phase 2 does not re-inject RAG**; it works only from persona plus the private reasoning. This framing is what fixed the phase-2 "voice bug" (Hal answering *about* the reasoning instead of *as* himself).

If the user hits Stop during phase 1, phase 2 never opens. The REASON instruction is itself live-overridable (via `SET_REASONING_PROMPT` or RoboRunner) through a `{question}` placeholder, so the directive can be A/B-tested without a rebuild.

### Thermal pacing

A thermal governor paces on-device generation against real device heat. The premise: **all** generation heats the chip (every token is near-full-duty GPU and Neural Engine work), so the risk grows with sustained heavy use, independent of what the model is saying. The cure is to pace generation itself so the chip never pegs. Pacing is awaited at each generation-chunk boundary, reads the device thermal state, and yields proportionally:

| Thermal state | Behavior |
|---|---|
| Nominal (cold) | **Nothing.** Full speed, zero cost. The common case is never touched. |
| Fair | About 60 ms yield, a near-imperceptible slowing of the climb. |
| Serious | About 250 ms back-off, the real backstop; Hal can also say "I'm running warm" in character. |
| Critical | **Hold** generation entirely, re-checking on a roughly one-second cadence until the device drops back down. |

Pacing always honors cancellation, so a user Stop is never stuck behind a cooldown. Thermal state is also exposed to feed Hal's in-character "let me slow down" behavior, so the pacing and the personality moment come from one source. There is a second, complementary knob: a **proactive per-chunk delay** applied every chunk regardless of thermal state (a leading-indicator control that limits token rate *before* heat builds). It is off for light models; the shipped use is a per-model throttle for the 8B Ternary Bonsai model during two-phase thinking, whose active-parameter count overheats the reason and answer passes. The design posture: the normal, cool experience must be completely untouched, and the one time the user notices anything the device is genuinely hot, at which point an honest "I'm running warm" beats a silent throttle.
