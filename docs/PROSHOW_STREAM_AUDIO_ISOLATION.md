# Stream audio — 5-minute isolation

Run **before** trusting code fixes. Split **mix/encode** vs **RTMP** in one pass.

| Step | What to do | If diagnosis holds |
|------|------------|-------------------|
| 1 | Go live with **camera + mic only** (mute slide, soundboard, desktop) | Flutter stops → multi-lane min-sync was likely involved |
| 2 | **Program-mix headphones** (Right Inspector) vs **viewer** | Both cut → `ProgramAACEncoder` / gates / silence AUs. Headphones clean, viewer bad → `ProgramAudioBus` pump or RTMP queue |
| 3 | Watch desk **RTMP audio tag drops** (`outboundNetworkAudioDropCount`) | Stays 0 during flutter → loss is **before** RTMP (AAC pump / silence generator / lanes) |
| 4 | Watch **composite skips** vs player loading | Skips rise with spinner → A/V skew or keyframe recovery after queue flush |

While live, Console filter: `subsystem:com.kaleel.proshow category:StreamAudio` (1 Hz lane + silence ratio log).
