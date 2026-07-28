# BabySleepTracker

BabySleepTracker is a premium SwiftUI baby sleep tracking app that helps parents log naps, night sleep, wake-up times, and wake periods while receiving AI-assisted sleep predictions and coaching insights.

The app combines a calm daily tracking experience with an agent-based prediction system that learns from a baby's rhythm over time.

---

## Overview

BabySleepTracker is designed for parents who want a simple but intelligent way to understand their baby's sleep patterns.

The app supports day naps, night sleep, ongoing sleep sessions, wake-up logging, wake periods, daily summaries, bedtime guidance, and an AI Coach experience that explains what to do next and why.

The product goal is to make baby sleep tracking feel clear, calm, and decision-oriented instead of data-heavy.

---

## Screenshots

Add app screenshots under a `screenshots/` folder and replace the paths below.

| Home Dashboard | AI Coach | History |
|---|---|---|
| `screenshots/home.png` | `screenshots/ai-coach.png` | `screenshots/history.png` |

Recommended screenshots:

- Home dashboard with next nap / bedtime card
- Active night sleep state
- Logged wake-up time state
- AI Coach Today tab
- AI Coach Logic tab
- History daily detail screen

---

## Architecture Diagram

```mermaid
flowchart TD
    App[BabySleepTracker App] --> UI[SwiftUI Views]

    UI --> Home[Home Dashboard]
    UI --> Coach[AI Coach]
    UI --> History[History]
    UI --> Forms[Add / Edit Sheets]

    Forms --> Records[Sleep Records]
    Forms --> WakeRecords[Daily Wake Records]
    Forms --> Breaks[Wake Periods]

    Records --> Storage[UserDefaults Persistence]
    WakeRecords --> Storage
    Breaks --> Storage

    Storage --> Memory[SleepMemoryStore / Local Loaders]
    Memory --> Orchestrator[SleepCoachOrchestrator]

    Orchestrator --> PhaseAgent[Phase Agent]
    Orchestrator --> PatternAgent[Pattern Agent]
    Orchestrator --> DaytimeAgent[Daytime Prediction Agent]
    Orchestrator --> NightAgent[Night Prediction Agent]
    Orchestrator --> TransitionAgent[Nap Transition Agent]
    Orchestrator --> InsightAgent[Insight Agent]
    Orchestrator --> OvertiredCalc[Overtired Calculator]
    Orchestrator --> LLMAgent[LLM Coach Agent]

    PhaseAgent --> Snapshot[Orchestrated Snapshot]
    PatternAgent --> Snapshot
    DaytimeAgent --> Snapshot
    NightAgent --> Snapshot
    TransitionAgent --> Snapshot
    InsightAgent --> Snapshot
    OvertiredCalc --> Snapshot
    LLMAgent --> CoachResponse[LLM Coach Response]

    Snapshot --> Home
    Snapshot --> Coach
    Snapshot --> History
    CoachResponse --> Coach
```

---

## Core Features

- Sleep session logging  
  Track day naps and night sleep with start time, duration, and ongoing state.

- Wake-up tracking  
  Log the baby's actual morning wake-up time to improve daily nap predictions.

- Wake periods  
  Add awake intervals inside naps or night sleep and subtract them from net sleep.

- Smart home dashboard  
  See the next nap, bedtime window, daily rhythm, wake-up status, and sleep summary in one premium dashboard.

- Ongoing sleep support  
  Keep night sleep or naps active until the user ends them or a valid wake-up time closes the session.

- AI Coach  
  Get nap timing, bedtime guidance, pattern insights, confidence levels, and explanation logic.

- History and day detail  
  Review previous days, inspect records, and understand sleep distribution over time.

---

## AI Pipeline

```mermaid
flowchart LR
    Input[Sleep + Wake Records] --> Quality[Data Quality Checks]
    Input --> Phase[Phase Detection]
    Input --> Pattern[Pattern Extraction]

    Phase --> Prediction[Prediction Layer]
    Pattern --> Prediction
    Quality --> Prediction

    Prediction --> Daytime[Next Nap Prediction]
    Prediction --> Night[Bedtime Window]
    Prediction --> Transition[Nap Transition Assessment]

    Daytime --> Snapshot[Coach Snapshot]
    Night --> Snapshot
    Transition --> Snapshot

    Snapshot --> RuleInsights[Rule-Based Insights]
    Snapshot --> LLM[LLM Coach Response]
    RuleInsights --> CoachUI[AI Coach UI]
    LLM --> CoachUI
```

The AI system is intentionally layered:

- Rule-based agents provide deterministic and reliable sleep guidance.
- Pattern analysis personalizes wake windows over time.
- The LLM layer adds natural-language coaching, pattern interpretation, and parent-friendly explanations.
- The UI separates immediate guidance from model logic so the user can understand both what to do and why.

---

## Wake-Up / Night Sleep State Machine

```mermaid
stateDiagram-v2
    [*] --> NoNightSleep

    NoNightSleep --> OngoingNightSleep: User starts night sleep
    NoNightSleep --> WakeLogged: User logs morning wake-up

    OngoingNightSleep --> OngoingNightSleep: Baby still sleeping
    OngoingNightSleep --> ClosedNightSleep: User manually ends sleep

    OngoingNightSleep --> ClosedNightSleep: Wake-up time > night sleep start
    OngoingNightSleep --> OngoingNightSleep: Wake-up time < night sleep start

    ClosedNightSleep --> WakeLogged: User logs wake-up time
    WakeLogged --> DayStarted: Wake-up saved for today

    DayStarted --> DayNapLogged: User logs nap
    DayNapLogged --> DayStarted: Nap completed

    DayStarted --> OngoingNightSleep: User starts new night sleep

    OngoingNightSleep --> StaleAutoClose: Session passes stale threshold
    StaleAutoClose --> ClosedNightSleep: App closes old ongoing session

    note right of OngoingNightSleep
        If a morning wake-up is entered after
        an evening night sleep has already started,
        the wake-up time is earlier than the sleep start.
        In that case, the app keeps night sleep ongoing.
    end note

    note right of ClosedNightSleep
        If wake-up time is after the ongoing
        night sleep start, it safely closes
        the night sleep session.
    end note
```

---

## Data Flow

```mermaid
flowchart LR
    User[Parent Input] --> AddSleep[Add Sleep Session]
    User --> AddWake[Add Wake-Up Time]
    User --> AddBreak[Add Wake Period]

    AddSleep --> SleepRecord[SleepRecord]
    AddWake --> DailyWakeRecord[DailyWakeRecord]
    AddBreak --> BreakRecord[Wake Period Record]

    SleepRecord --> LocalStorage[UserDefaults]
    DailyWakeRecord --> LocalStorage
    BreakRecord --> LocalStorage

    LocalStorage --> Notifications[Change Notifications]
    Notifications --> Reload[Reload Local Data]

    Reload --> Orchestrator[SleepCoachOrchestrator]

    Orchestrator --> DataPrep[Prepare Daily Sleep Data]
    DataPrep --> Phase[Phase Detection]
    DataPrep --> Pattern[Pattern Analysis]
    DataPrep --> Daytime[Next Nap Prediction]
    DataPrep --> Night[Bedtime Prediction]
    DataPrep --> Insights[Rule-Based Insights]
    DataPrep --> Quality[Data Quality Checks]

    Phase --> Snapshot[Orchestrated Snapshot]
    Pattern --> Snapshot
    Daytime --> Snapshot
    Night --> Snapshot
    Insights --> Snapshot
    Quality --> Snapshot

    Snapshot --> HomeUI[Home Dashboard]
    Snapshot --> CoachUI[AI Coach]
    Snapshot --> HistoryUI[History]

    Snapshot --> LLMAgent[LLM Coach Agent]
    LLMAgent --> LLMResponse[Coach Message / Pattern Insight / Alert]
    LLMResponse --> CoachUI
```

---

## Project Structure

```txt
BabySleepTracker/
├── Models/
│   ├── SleepRecord.swift
│   ├── SleepKind.swift
│   └── SegmentKind.swift
├── Views/
│   ├── SleepListView.swift
│   ├── InsightView.swift
│   ├── HistoryView.swift
│   ├── DayDetailView.swift
│   ├── AddRecordView.swift
│   └── AddBreakView.swift
├── ViewModels/
│   ├── AddRecordViewModel.swift
│   ├── SleepListViewModel.swift
│   └── DayDetailViewModel.swift
├── Services/
│   ├── SleepCoachOrchestrator.swift
│   ├── SleepCoachLLMAgent.swift
│   ├── SleepAPI.swift
│   └── SleepStore.swift
├── Agents/
│   ├── Implements/
│   └── Protocols/
├── Memory/
│   └── SleepMemoryStore.swift
└── Utils/
    ├── Date+Extensions.swift
    └── TimeFormat.swift
```

---

## Technology Stack

- Swift
- SwiftUI
- MVVM-inspired architecture
- Agent-based prediction architecture
- UserDefaults persistence
- NotificationCenter-based refresh flow
- XCTest
- Google Generative AI Swift SDK

---

## Engineering Decisions

- SwiftUI-first interface for fast iteration and reactive state updates.
- Lightweight local persistence using UserDefaults for early product velocity.
- Agent-based sleep intelligence instead of one large prediction service.
- Deterministic rule-based prediction as the foundation, with LLM coaching layered on top.
- Separate wake-up records from sleep records to keep morning anchors explicit.
- Ongoing sleep sessions support live duration calculation without requiring immediate end-time entry.
- AI Coach UI is split into Today and Logic views to keep guidance actionable and transparent.
- Wake-up time can close an ongoing night sleep only when it occurs after the sleep start time.

---

## Testing Strategy

Current test coverage focuses on:

- Sleep API behavior
- Add record validation
- Basic model construction

Recommended next testing layers:

- Wake-up logging and ongoing night sleep closure rules
- Net sleep calculation with wake periods
- Daytime prediction edge cases
- Night sleep prediction windows
- AI Coach snapshot generation
- UI state tests for logged / missing wake-up states

---

## Challenges

Key engineering challenges in this project:

- Handling ongoing sleep sessions across calendar boundaries.
- Preventing morning wake-up logs from incorrectly closing newly started night sleep sessions.
- Balancing age-based sleep guidance with personalized baby-specific rhythm.
- Keeping AI Coach explanations useful without making the UI feel clinical.
- Designing a premium interface for tired parents who need clarity, not complexity.
- Maintaining predictable state updates across UserDefaults, NotificationCenter, and SwiftUI views.

---

## Roadmap

```mermaid
timeline
    title BabySleepTracker Roadmap

    Phase 1 : Core sleep logging
            : Day naps
            : Night sleep
            : Wake periods
            : Wake-up records

    Phase 2 : Premium dashboard
            : Next nap card
            : Bedtime state
            : Daily summary
            : Timeline UI

    Phase 3 : AI Coach
            : Rule-based prediction
            : Pattern analysis
            : LLM coaching
            : Explanation screen

    Phase 4 : Data quality
            : Completeness score
            : Plausibility checks
            : Missing signal detection

    Phase 5 : Advanced personalization
            : Weekly trends
            : Adaptive wake windows
            : Regression detection
            : Notification timing

    Phase 6 : Production readiness
            : Cloud sync
            : Authentication
            : Exportable reports
            : App Store polish
```

---

## Future Improvements

- SwiftData or Core Data migration
- iCloud sync
- Push notifications before predicted naps
- Weekly and monthly sleep analytics
- Exportable pediatric sleep reports
- Better test coverage for prediction agents
- App Store-ready onboarding and settings polish

---

## Author

**Büşra Kalay**  
iOS Developer | Swift | SwiftUI | MVVM | AI-assisted mobile products

LinkedIn: https://linkedin.com/in/busrakalay  
GitHub: https://github.com/busrayildiiz

---

## Note

This project is actively evolving as a premium iOS sleep tracking and AI coaching experience.
