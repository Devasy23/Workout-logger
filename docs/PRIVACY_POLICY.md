# Privacy Policy for RepForge

**Last Updated: September 11, 2026**  
**Effective Date: September 11, 2026**

RepForge ("we", "our", or "the app") is developed by Devasy Patel as an open-source, privacy-first workout logging application. This Privacy Policy explains our practices regarding the collection, use, disclosure, and safeguarding of your information when you use the RepForge mobile application.

---

## 1. Core Principle: Local-First & Privacy-Focused

RepForge is designed with an offline-first, privacy-by-design architecture:
- **No Account Required:** You do not need to create an account, log in, or provide an email address to use RepForge.
- **Local Storage:** All workout logs, routines, personal records (PRs), analytics, and preferences are stored exclusively on your device using a local SQLite database.
- **No Developer Servers:** We do not operate developer backend servers, remote databases, or cloud sync servers. Your workout data stays on your device under your direct control.

---

## 2. Information We Handle

### A. Workout & Fitness Data (Stored Locally)
- Exercises, sets, repetitions, weights, and rest intervals.
- Custom workout routines, programs, and target goals.
- Personal records, 1-Rep Max (1RM) estimates, and workout notes.
- *Storage:* Kept solely within the app's protected sandbox storage on your local device.

### B. Health Connect Data (Android Health Connect)
RepForge integrates with Android Health Connect to provide cross-app workout synchronization and training readiness insights. This integration is optional and requires your explicit, granular runtime consent.

RepForge may request the following Health Connect permissions:
- `android.permission.health.WRITE_EXERCISE`: To write workout sessions completed in RepForge to your Health Connect store so other health applications can recognize your workouts.
- `android.permission.health.READ_EXERCISE`: To view previously logged workouts for historical consistency.
- `android.permission.health.READ_SLEEP`: To read sleep duration and stages.
- `android.permission.health.READ_HEART_RATE`: To read heart rate data recorded during rest and exercise.
- `android.permission.health.READ_RESTING_HEART_RATE`: To read resting heart rate metrics.
- `android.permission.health.READ_HEART_RATE_VARIABILITY`: To read HRV metrics.

**Purpose of Health Connect Usage:**
- Sleep, heart rate, resting heart rate, and HRV data are used exclusively to calculate your daily **Readiness & Recovery Score** within the app, helping you determine appropriate training intensity and volume.
- Exercise read/write permissions allow your workout activity to synchronize seamlessly with your broader personal health ecosystem.

**Strict Health Connect Policy Commitments:**
- **No External Transmission:** Data read from Health Connect is processed strictly on your local device. It is never transmitted to developer servers, third parties, or advertising platforms.
- **No Commercial Exploitation:** Health Connect data is never sold, licensed, or used for targeted advertising, marketing, data brokering, creditworthiness determinations, or insurance underwriting.
- **User Control:** You can grant, revoke, or modify Health Connect permissions at any time via your Android device settings (**Settings → Security & Privacy → Privacy → Health Connect → App permissions → RepForge**).

---

## 3. Optional Features: Generative AI (AI Coach & Routine Optimizer)

RepForge includes an optional AI Coach and Routine Optimizer feature powered by the Google Gemini API.

- **Disabled by Default:** This feature is completely inactive until you explicitly opt in and provide your own personal Google Gemini API key in **Settings → AI Settings**.
- **Data Transmission with Your Own Key:** If you choose to use the AI Coach, your specific coaching prompt and relevant workout context (such as recent exercise history) are transmitted directly from your device over encrypted HTTPS to Google's Gemini API servers.
- **No Developer Intermediary:** RepForge does not route AI requests through any intermediary proxy or developer server. The communication is directly between your device and Google's Gemini service under your personal API key.
- **Google Privacy Policy:** Data submitted to Google via the Gemini API is governed by [Google's Privacy Policy](https://policies.google.com/privacy) and Google API Terms of Service.

---

## 4. Device Permissions

RepForge requests only the minimal set of permissions necessary to function:
| Permission | Purpose |
| :--- | :--- |
| `INTERNET` | Required only if you configure the optional AI Coach with your Gemini API key. Also required by the system network stack for checking Health Connect API availability. Core workout logging and analytics operate fully offline. |
| Health Connect Permissions (`READ_SLEEP`, `READ_HEART_RATE`, `READ_RESTING_HEART_RATE`, `READ_HEART_RATE_VARIABILITY`, `READ_EXERCISE`, `WRITE_EXERCISE`) | Used exclusively to calculate daily readiness/recovery scores and sync workout records within Android Health Connect. Optional and revocable. |

---

## 5. Third-Party Libraries, Analytics, and Advertising

- **Zero Advertising:** RepForge contains no advertisements, sponsored content, or ad-tracking SDKs.
- **Zero Third-Party Telemetry:** RepForge contains no third-party analytics trackers (such as Google Analytics for Firebase, Mixpanel, or Facebook SDK). We do not track your user behavior or session activity.
- **Local Assets & Fonts:** Fonts (Geist and GeistMono) and icons are bundled directly within the app binary. The app does not load fonts or UI assets from external CDNs at runtime.

---

## 6. Data Retention, Backup, and Deletion

- **Data Retention:** Your data remains on your device for as long as you keep RepForge installed.
- **User-Controlled Export / Backup:** RepForge allows you to generate a full, human-readable JSON backup of your workout data at any time via **Settings → Backup & Restore → Export**. You can securely store this backup wherever you choose.
- **Data Deletion:** You can delete all your data at any time by:
  1. Using **Settings → Clear Data / Reset** within the app, or
  2. Clearing app storage in Android settings (**Settings → Apps → RepForge → Storage & cache → Clear storage**), or
  3. Uninstalling RepForge from your device.
  Since we do not store your data on external servers, uninstalling the app permanently removes all local data.

---

## 7. Children's Privacy

RepForge is not directed to children under the age of 13. Because RepForge does not collect personal identification information, we do not knowingly collect personal information from children under 13.

---

## 8. Open Source & Transparency

RepForge is open-source software licensed under the Apache License 2.0. You can inspect the complete source code, verify all data handling, and review build configurations on GitHub:  
**Source Code:** [https://github.com/Devasy/RepForge](https://github.com/Devasy/RepForge)

---

## 9. Changes to This Privacy Policy

We may update our Privacy Policy from time to time. Any changes will be posted to this page with an updated "Last Updated" date and reflected in new app releases.

---

## 10. Contact Us

If you have questions, feedback, or concerns about this Privacy Policy or RepForge's privacy practices, please contact:

- **Developer:** Devasy Patel
- **Email:** [patel.devasy.23@gmail.com](mailto:patel.devasy.23@gmail.com)
- **GitHub Issues:** [https://github.com/Devasy/RepForge/issues](https://github.com/Devasy/RepForge/issues)
- **Repository:** [https://github.com/Devasy/RepForge](https://github.com/Devasy/RepForge)
