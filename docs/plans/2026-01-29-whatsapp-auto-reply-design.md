# WhatsApp Auto-Reply for macOS

## Overview

A Swift menu bar app that monitors WhatsApp Desktop and generates automatic responses using a local LLM (Ollama), mimicking the user's messaging style based on imported chat history.

## Goals

- Respond to WhatsApp messages automatically when enabled
- Match the user's personal messaging style per contact
- Run entirely locally for privacy (no cloud APIs)
- Minimal UI with easy toggle on/off

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Swift macOS App                       │
├─────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Menu Bar UI  │  │ WhatsApp     │  │ Response      │  │
│  │ (Toggle,     │  │ Monitor      │  │ Generator     │  │
│  │  Contacts)   │  │ (Accessibility│  │ (Ollama API)  │  │
│  └──────────────┘  │  API)        │  └───────────────┘  │
│                    └──────────────┘                      │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Contacts Database (SQLite)                       │   │
│  │ - Per-contact message history                    │   │
│  │ - Parsed from WhatsApp chat exports              │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
┌─────────────────┐  ┌─────────────────┐
│ WhatsApp Desktop│  │ Ollama (local)  │
│ via Accessibility│  │ llama3.2:3b    │
└─────────────────┘  └─────────────────┘
```

## Components

### 1. Menu Bar UI

Minimal SwiftUI menu bar app:

```
┌─────────────────────────────┐
│ 💬 WhatsApp Auto-Reply      │
├─────────────────────────────┤
│ Contacts:                   │
│   ● Amor (active)           │
│   ○ Frank Ferreira          │
│   ● Bianca Silva (active)   │
├─────────────────────────────┤
│ Import Chat Export...       │
│ View Response Log...        │
│ Quit                        │
└─────────────────────────────┘
```

Features:
- Per-contact toggle for auto-reply
- Status indicator (green = active, gray = off)
- Import new chat exports via file picker
- View response history log

### 2. WhatsApp Monitor (Accessibility API)

Uses macOS Accessibility APIs to interact with WhatsApp Desktop:

**Reading messages:**
- Access WhatsApp's window via `AXUIElement`
- Navigate accessibility tree to find chat messages
- Poll every 2-3 seconds for new messages
- Detect unread indicators/badges

**Sending messages:**
- Focus the text input field via accessibility
- Simulate keyboard input to type response
- Simulate Enter key to send

**Requirements:**
- App must be granted Accessibility permission
- WhatsApp Desktop must be open (not minimized)

### 3. Response Generator (Ollama)

**Chat parsing:**
- Parse WhatsApp export `_chat.txt` files
- Extract user's messages with context (preceding message)
- Store in SQLite with contact association

**Prompt construction:**
```
You are Iago Cavalcante. Respond exactly as he would based on these example conversations:

[Example 1]
{contact}: {their_message}
Iago: {your_response}

[Example 2]
...

Now respond to this new message in the same style (casual, short, Portuguese):
{contact}: {new_message}
Iago:
```

**Style characteristics to preserve:**
- Casual, short messages
- Brazilian Portuguese
- Uses "kkkk", emojis, informal spelling
- Multiple short messages vs one long one

### 4. Contacts Database (SQLite)

Schema:
```sql
CREATE TABLE contacts (
    id INTEGER PRIMARY KEY,
    name TEXT UNIQUE,
    auto_reply_enabled INTEGER DEFAULT 0,
    created_at TIMESTAMP
);

CREATE TABLE messages (
    id INTEGER PRIMARY KEY,
    contact_id INTEGER,
    sender TEXT,  -- 'user' or 'contact'
    content TEXT,
    timestamp TIMESTAMP,
    FOREIGN KEY (contact_id) REFERENCES contacts(id)
);
```

## Safety Features

1. **Manual activation** - Auto-reply only works when explicitly toggled on per contact
2. **5-second delay** - Shows notification before sending, can cancel
3. **Response logging** - All sent messages logged to file for review
4. **Contact whitelist** - Only responds to imported/recognized contacts

## Error Handling

| Situation | Behavior |
|-----------|----------|
| WhatsApp not open | Show status in menu bar, pause auto-reply |
| Ollama not running | Show error notification, pause |
| Unknown contact | Ignore message |
| Image/audio message | Skip, wait for text |
| Ollama timeout (>10s) | Skip message |
| Rapid messages | Bundle and respond once |

## File Locations

- Database: `~/Library/Application Support/WhatsAppAutoReply/data.sqlite`
- Logs: `~/Library/Application Support/WhatsAppAutoReply/responses.log`

## Prerequisites

1. **Ollama** installed with `llama3.2:3b` model
   ```bash
   ollama pull llama3.2:3b
   ```

2. **Accessibility permission** granted in System Preferences > Privacy & Security > Accessibility

3. **WhatsApp Desktop** installed and open

## Tech Stack

- Swift 5.9+
- SwiftUI (menu bar UI)
- ApplicationServices framework (Accessibility API)
- SQLite.swift (database)
- URLSession (Ollama HTTP API)

## Out of Scope

- Processing images, audio, or video messages
- Group chat support
- End-to-end encryption handling (uses visible UI text)
- WhatsApp Web (desktop app only)
