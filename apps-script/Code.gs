/**
 * لوحة زبائن عالم محمد تيفي: الربط مع Google Sheets
 *
 * الكود هذا يشتغل داخل Google Sheet حقك (Extensions → Apps Script)،
 * ويخلي اللوحة تقرأ وتكتب بيانات الزبائن في الشيت.
 *
 * ⚠️ غيّر كلمة السر تحت قبل ما تسوي Deploy، ولا تشاركها مع أحد.
 */
const PASSWORD = 'غيّر-كلمة-السر-هنا';

const CUSTOMERS_SHEET = 'الزبائن';
const SETTINGS_SHEET = 'الإعدادات';

// ترتيب الأعمدة في شيت الزبائن (لا تغيّر الترتيب بعد ما تبدأ)
const COLUMNS = [
  ['id', 'المعرف'],
  ['name', 'الاسم'],
  ['phone', 'الجوال'],
  ['mac', 'MAC'],
  ['deviceKey', 'Device Key'],
  ['screen', 'نوع الشاشة'],
  ['pkg', 'الباقة'],
  ['startDate', 'تاريخ التفعيل'],
  ['endDate', 'تاريخ الانتهاء'],
  ['daysLeft', 'الأيام المتبقية'],
  ['notes', 'ملاحظات'],
  ['referredBy', 'أحاله'],
  ['qualityDone', 'فحص الجودة'],
  ['sent', 'الرسائل المرسلة'],
  ['payments', 'الدفعات'],
  ['createdAt', 'تاريخ الإضافة'],
  ['example', 'مثال'],
];
const KEYS = COLUMNS.map(function (c) { return c[0]; });
const JSON_KEYS = ['sent', 'payments'];
const BOOL_KEYS = ['qualityDone', 'example'];
const DAYS_COL = KEYS.indexOf('daysLeft') + 1;
const END_COL = KEYS.indexOf('endDate') + 1;

function doGet() {
  return ContentService.createTextOutput('لوحة محمد تيفي: الربط شغال ✅');
}

function doPost(e) {
  let req;
  try {
    req = JSON.parse(e.postData.contents);
  } catch (err) {
    return out_({ ok: false, error: 'bad_request' });
  }
  if (!req || req.pass !== PASSWORD) {
    Utilities.sleep(800); // يبطّئ محاولات تخمين كلمة السر
    return out_({ ok: false, error: 'auth' });
  }
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    ensureSheets_();
    switch (req.action) {
      case 'ping':
        return out_({ ok: true });
      case 'load':
        return out_({ ok: true, customers: readCustomers_(), settings: readSettings_() });
      case 'save':
        saveCustomer_(req.customer);
        return out_({ ok: true });
      case 'delete':
        deleteCustomer_(req.id);
        return out_({ ok: true });
      case 'saveSettings':
        writeSettings_(req.settings);
        return out_({ ok: true });
      default:
        return out_({ ok: false, error: 'unknown_action' });
    }
  } catch (err) {
    return out_({ ok: false, error: 'server', message: String(err && err.message || err) });
  } finally {
    lock.releaseLock();
  }
}

/* ---------- sheets ---------- */
function ensureSheets_() {
  const ss = SpreadsheetApp.getActive();
  let sh = ss.getSheetByName(CUSTOMERS_SHEET);
  if (!sh) {
    sh = ss.insertSheet(CUSTOMERS_SHEET, 0);
    sh.getRange(1, 1, 1, COLUMNS.length)
      .setValues([COLUMNS.map(function (c) { return c[1]; })])
      .setFontWeight('bold').setBackground('#E3E7FF');
    sh.setFrozenRows(1);
    sh.setRightToLeft(true);
    // كل الأعمدة نص عادي عشان الجوال والتواريخ ما تتغير، ما عدا الأيام المتبقية
    sh.getRange(1, 1, sh.getMaxRows(), COLUMNS.length).setNumberFormat('@');
    sh.getRange(2, DAYS_COL, sh.getMaxRows() - 1, 1).setNumberFormat('0');
    sh.hideColumns(KEYS.indexOf('id') + 1);
    addColors_(sh);
  }
  let st = ss.getSheetByName(SETTINGS_SHEET);
  if (!st) {
    st = ss.insertSheet(SETTINGS_SHEET);
    st.getRange('A1:B1').setValues([['settings', '{}']]);
    st.getRange('B1').setNumberFormat('@');
    st.setRightToLeft(true);
  }
}

// تلوين عمود الأيام المتبقية داخل الشيت نفسه
function addColors_(sh) {
  const range = sh.getRange(2, DAYS_COL, sh.getMaxRows() - 1, 1);
  const rule = function (formula, bg, fg) {
    return SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied(formula).setBackground(bg).setFontColor(fg)
      .setRanges([range]).build();
  };
  const c = columnLetter_(DAYS_COL) + '2';
  sh.setConditionalFormatRules([
    rule('=AND(ISNUMBER(' + c + '),' + c + '<0)', '#E6E9F0', '#5A6380'),
    rule('=AND(ISNUMBER(' + c + '),' + c + '<=1)', '#FADDE1', '#B01F33'),
    rule('=AND(ISNUMBER(' + c + '),' + c + '<=3)', '#FCE4D1', '#AE4D0A'),
    rule('=AND(ISNUMBER(' + c + '),' + c + '<=7)', '#FAEFCF', '#8F6300'),
    rule('=ISNUMBER(' + c + ')', '#DBF2E6', '#11764A'),
  ]);
}

function columnLetter_(n) {
  let s = '';
  while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); }
  return s;
}

/* ---------- customers ---------- */
function readCustomers_() {
  const sh = SpreadsheetApp.getActive().getSheetByName(CUSTOMERS_SHEET);
  const last = sh.getLastRow();
  if (last < 2) return [];
  const rows = sh.getRange(2, 1, last - 1, COLUMNS.length).getDisplayValues();
  const list = [];
  rows.forEach(function (r) {
    if (!r[0]) return;
    const c = {};
    KEYS.forEach(function (k, i) {
      if (k === 'daysLeft') return;
      let v = r[i];
      if (JSON_KEYS.indexOf(k) >= 0) { try { v = v ? JSON.parse(v) : (k === 'payments' ? [] : {}); } catch (e) { v = k === 'payments' ? [] : {}; } }
      else if (BOOL_KEYS.indexOf(k) >= 0) v = v === 'TRUE' || v === 'true' || v === 'نعم';
      else if (k === 'createdAt') v = Number(v) || 0;
      c[k] = v;
    });
    list.push(c);
  });
  return list;
}

function rowFor_(c, rowNum) {
  return KEYS.map(function (k) {
    if (k === 'daysLeft') {
      const e = columnLetter_(END_COL) + rowNum;
      return '=IF(' + e + '="","",DATEVALUE(' + e + ')-TODAY())';
    }
    const v = c[k];
    if (JSON_KEYS.indexOf(k) >= 0) return JSON.stringify(v || (k === 'payments' ? [] : {}));
    if (BOOL_KEYS.indexOf(k) >= 0) return v ? 'نعم' : '';
    const s = v === undefined || v === null ? '' : String(v);
    return /^[=+\-@]/.test(s) ? "'" + s : s; // يمنع تحويل النص لمعادلة
  });
}

function findRow_(sh, id) {
  const last = sh.getLastRow();
  if (last < 2) return -1;
  const ids = sh.getRange(2, 1, last - 1, 1).getValues();
  for (let i = 0; i < ids.length; i++) if (String(ids[i][0]) === String(id)) return i + 2;
  return -1;
}

function saveCustomer_(c) {
  if (!c || !c.id || !c.name) throw new Error('بيانات الزبون ناقصة');
  const sh = SpreadsheetApp.getActive().getSheetByName(CUSTOMERS_SHEET);
  let row = findRow_(sh, c.id);
  if (row < 0) row = sh.getLastRow() + 1;
  if (row > sh.getMaxRows()) sh.insertRowsAfter(sh.getMaxRows(), 200);
  sh.getRange(row, 1, 1, COLUMNS.length).setValues([rowFor_(c, row)]);
}

function deleteCustomer_(id) {
  const sh = SpreadsheetApp.getActive().getSheetByName(CUSTOMERS_SHEET);
  const row = findRow_(sh, id);
  if (row > 0) sh.deleteRow(row);
}

/* ---------- settings ---------- */
function readSettings_() {
  const st = SpreadsheetApp.getActive().getSheetByName(SETTINGS_SHEET);
  try { return JSON.parse(st.getRange('B1').getDisplayValue() || '{}'); } catch (e) { return {}; }
}
function writeSettings_(s) {
  SpreadsheetApp.getActive().getSheetByName(SETTINGS_SHEET).getRange('B1').setValue(JSON.stringify(s || {}));
}

function out_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// شغّل هالدالة مرة وحدة من المحرر عشان يتجهز الشيت (اختياري)
function setup() {
  ensureSheets_();
}
