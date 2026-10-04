# تنزيل Neptune Remote على الراسبيري باي

دليل سريع بالعربي. كل الأوامر دي بتتنفذ **على الراسبيري باي** نفسه
(عن طريق SSH أو الشاشة مباشرة).

> **مهم:** التنزيل ده **مبيلمسش** Klipper ولا Moonraker ولا `printer.cfg`.
> بيركّب خدمة جديدة جنبهم بس.

---

## المطلوب قبل ما تبدأ

| الحاجة | ليه |
| --- | --- |
| راسبيري باي شغال عليه Klipper + Moonraker | ده اللي التطبيق بيتكلم معاه |
| مساحة فاضية حوالي ٢ جيجا | البرنامج + البايثون + الفيديوهات |
| اتصال إنترنت على الباي | علشان يحمّل الحزم |

اتأكد إن Moonraker شغال:

```bash
systemctl status moonraker
```

---

## الطريقة الأولى: من ملف (لو استلمت `neptune-remote-pi.tar.gz`)

**١. انقل الملف للباي** من الكمبيوتر بتاعك:

```bash
scp neptune-remote-pi.tar.gz pi@100.78.2.66:~/
```

**٢. ادخل على الباي وفك الضغط:**

```bash
ssh pi@100.78.2.66
tar -xzf ~/neptune-remote-pi.tar.gz -C ~/
cd ~/neptune-remote
```

**٣. شغّل التنزيل:**

```bash
cd raspberry-pi
chmod +x install.sh
./install.sh
```

---

## الطريقة التانية: من GitHub مباشرة

```bash
cd ~
git clone https://github.com/Alaa2134/DARKS.git
cd DARKS/neptune-remote/raspberry-pi
chmod +x install.sh
./install.sh
```

---

## التنزيل بيعمل إيه بالظبط

السكريبت **آمن تشغّله أكتر من مرة**، وبيعمل الآتي بالترتيب:

1. يتأكد إنك على لينكس ومعاك `sudo`.
2. يبص على Klipper و Moonraker **من غير ما يعدّل فيهم**.
3. يركّب الحزم دي من `apt`:
   - `python3`, `python3-venv`, `python3-pip`, `python3-dev`
   - `build-essential`, `curl`, `ca-certificates`
   - **`ffmpeg`** — للتسجيل والتايم لابس
   - **`v4l-utils`** — علشان يعرف الكاميرات المتوصلة
   > لو مش عايز الاتنين دول: `SKIP_MEDIA=1 ./install.sh`
4. ينسخ البرنامج في `/opt/neptune-remote`.
5. يعمل بيئة بايثون معزولة ويركّب فيها:
   `fastapi`, `uvicorn`, `httpx`, `pydantic`, `PyYAML`,
   `python-multipart`, `psutil`, `websockets`, `numpy`, `Pillow`
6. يدوّر على برنامج تقطيع، ولو ملقاش يحاول يركّب **PrusaSlicer**.
   > لو مش عايزه دلوقتي: `SKIP_SLICER=1 ./install.sh`
7. يفحص الكاميرا، و`ffmpeg`، ويضيف المستخدم لمجموعة `video`.
8. يركّب خدمة systemd اسمها `neptune-remote` ويشغّلها.

التنزيل بياخد من ٥ لـ ١٥ دقيقة على باي ٥ حسب الإنترنت.

---

## بعد التنزيل

**١. عدّل الإعدادات:**

```bash
sudo nano /opt/neptune-remote/config.yaml
```

اللي محتاج تظبطه:

```yaml
server:
  # توكن سري اختياري - لو حطيته، التطبيق لازم يبعته مع كل طلب
  api_token: ""

moonraker:
  host: "127.0.0.1"
  port: 7125

power:
  provider: "none"    # tuya | moonraker | webhook | demo | none

camera:
  stream_url: "http://127.0.0.1:8080/?action=stream"
```

لو هتستخدم مفتاح Tuya، حط بياناته هنا — **مش في التطبيق**:

```yaml
power:
  provider: "tuya"
  tuya:
    endpoint: "https://openapi.tuyaeu.com"
    access_id: "..."
    access_secret: "..."
    device_id: "..."
```

> `config.yaml` مستبعد من git، فأسرارك مش هتترفع أبداً.
> التفاصيل في `docs/TUYA_SETUP.md`.

**٢. أعد التشغيل:**

```bash
sudo systemctl restart neptune-remote
```

**٣. اتأكد إنه شغال:**

```bash
curl -s http://127.0.0.1:8710/api/health
```

المفروض يرجّع JSON فيه `"status": "ok"`.

**٤. هات عنوان Tailscale:**

```bash
tailscale ip -4
```

وحطه في التطبيق: **الإعدادات ← عنوان الراسبيري باي**.

---

## اختياري: مراقبة فشل الطباعة بنموذج مدرب

المراقب شغال من غير أي تنزيل إضافي — بيستخدم تحليل صورة مدمج،
والتطبيق بيقول لك بوضوح إنه تقريبي.

لو عايز تستخدم نموذج ONNX من عندك:

```bash
cd ~/DARKS/neptune-remote
./scripts/install_vision.sh
```

> المشروع **مبيجيش معاه نموذج**. النموذج اللي مختارتوش بنفسك
> صندوق أسود بياخد قرارات على طابعتك. التفاصيل في `docs/AI.md`.

---

## أوامر بتحتاجها

```bash
# حالة الخدمة
systemctl status neptune-remote

# اللوج مباشر
journalctl -u neptune-remote -f

# إعادة تشغيل
sudo systemctl restart neptune-remote

# وقف الخدمة
sudo systemctl stop neptune-remote

# التحديث لأحدث نسخة
cd ~/DARKS && git pull
cd neptune-remote/raspberry-pi && ./install.sh
```

---

## لو حصلت مشكلة

| المشكلة | الحل |
| --- | --- |
| الخدمة مش بتقوم | `journalctl -u neptune-remote -n 50` |
| التطبيق مش شايف الباي | اتأكد إن Tailscale شغال على الاتنين |
| `401 Invalid or missing API token` | التوكن في `config.yaml` مش زي اللي في التطبيق |
| "Slicer unavailable" | `sudo apt install prusa-slicer` — أو شوف `docs/SLICER.md` |
| "No camera detected" | `ls /dev/video*` — ولو فاضي شوف كابل الكاميرا |
| التسجيل مقفول | `sudo apt install ffmpeg` |

من جوه التطبيق كمان: **المساعدة ← فحص النظام** بيفحص كل طبقة لوحدها
ويقول لك بالظبط اللي واقع فين.

---

## الأمان

- **Moonraker مايتفتحش على الإنترنت أبداً.** Tailscale هي الحماية.
- الأسرار (Tuya، التوكن) في `config.yaml` على الباي بس — مش في التطبيق.
- التطبيق بيحفظ التوكن بتاعه في الـ Keychain بتاع الآيفون.
- التقارير والنسخ الاحتياطية بيتشال منها الأسرار قبل ما تتكتب.
