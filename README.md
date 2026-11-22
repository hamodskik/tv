# لوحة زبائن عالم محمد تيفي

لوحة لإدارة اشتراكات IPTV: تضيف الزبون وتشوف كم باقي له، وتطلع لك مهام التذكير كل يوم، وترسل رسائل واتساب جاهزة، وتجدد الاشتراك بضغطة.

```
الجوال / اللابتوب ──► GitHub Pages (index.html) ──► Supabase (قاعدة البيانات + تسجيل الدخول)
```

- **الواجهة:** `index.html` على GitHub Pages
- **البيانات:** في Supabase، ومحمية بقواعد صلاحيات داخل قاعدة البيانات نفسها
- **الدخول:** إيميل وكلمة سر لكل شخص، والتسجيل الذاتي مقفول

| الملف | وش هو |
|---|---|
| `index.html` | اللوحة |
| `config.js` | رابط مشروع Supabase والمفتاح العام |
| `supabase/schema.sql` | الجداول والصلاحيات، تلصقه مرة وحدة في Supabase |

---

## التجهيز (مرة وحدة، تقريباً 10 دقائق)

### 1) سوِّ مشروع في Supabase
1. ادخل [supabase.com](https://supabase.com) وسجّل (ببلاش).
2. **New project**:
   - **Name:** `tv`
   - **Database Password:** اضغط Generate واحفظها في مكان آمن (ما راح تحتاجها في اللوحة)
   - **Region:** اختر الأقرب لك، مثل `Frankfurt` أو `Mumbai`
3. استنى دقيقتين لين يجهز.

### 2) سوِّ الجداول
1. من القائمة: **SQL Editor ← New query**.
2. الصق محتوى [`supabase/schema.sql`](supabase/schema.sql) كامل ← **Run**.
3. لازم يطلع **Success. No rows returned**.

### 3) اقفل التسجيل وسوِّ حسابك
1. **Authentication ← Sign In / Providers**، وطفّي **Allow new users to sign up** ← Save.
   > هذا يمنع أي أحد يسوي لنفسه حساب.
2. **Authentication ← Users ← Add user ← Create new user**:
   - إيميلك وكلمة سر قوية (12 خانة أو أكثر)
   - فعّل **Auto Confirm User**

### 4) أضف نفسك كمالك
في **SQL Editor** شغّل هذا، بعد ما تغيّر الإيميل لإيميلك:
```sql
insert into public.staff (user_id, role)
select id, 'owner' from auth.users where email = 'اكتب-إيميلك-هنا'
on conflict (user_id) do update set role = 'owner';
```

### 5) اربط اللوحة
1. **Project Settings ← API** (أو **Data API**).
2. انسخ:
   - **Project URL** مثل `https://abcd1234.supabase.co`
   - **anon public** key (مفتاح طويل يبدأ بـ `eyJ`)
3. حطهم في `config.js`، أو أرسلهم لـ Claude يحطهم لك.

> ✅ مفتاح **anon** آمن ومصمم يكون عام، والحماية من قواعد قاعدة البيانات.
> ⛔ **لا تشارك أبداً** مفتاح `service_role` ولا كلمة سر قاعدة البيانات.

### 6) ادخل
افتح **https://hamodskik.github.io/tv/** وادخل بإيميلك وكلمة السر.

> 💡 على الجوال: من المتصفح اختر **إضافة إلى الشاشة الرئيسية**، وتصير اللوحة مثل التطبيق.

---

## إضافة موظف
1. **Authentication ← Users ← Add user** (إيميله وكلمة سر).
2. في SQL Editor:
```sql
insert into public.staff (user_id, role)
select id, 'staff' from auth.users where email = 'ايميل-الموظف';
```
الموظف يقدر يضيف زبائن ويعدلهم ويجددهم، بس **ما يقدر يحذف** ولا يغير الإعدادات.

لإيقاف موظف: احذفه من **Authentication ← Users**.

## الصلاحيات

| | المالك | الموظف | حساب مو مضاف | زائر بدون دخول |
|---|---|---|---|---|
| يشوف الزبائن | ✅ | ✅ | ❌ | ❌ |
| يضيف ويعدل ويجدد | ✅ | ✅ | ❌ | ❌ |
| يحذف زبون | ✅ | ❌ | ❌ | ❌ |
| يغير الإعدادات | ✅ | ❌ | ❌ | ❌ |

## الأمان
- المستودع ما فيه أي بيانات زبائن ولا كلمات سر.
- لو أحد فتح رابط اللوحة يشوف شاشة دخول بس.
- الصلاحيات مطبقة **داخل قاعدة البيانات**. حتى لو أحد عدّل كود اللوحة عنده، ما يقدر يوصل لشي.
- لو ضاع جوالك: **Authentication ← Users** ← حسابك ← غيّر كلمة السر.

## النسخ الاحتياطي
- **Table Editor ← customers ← Export to CSV** تحفظ نسخة في أي وقت.
- **Table Editor ← customers_status** يعرض لك الزبائن مرتبين حسب الأيام المتبقية.
