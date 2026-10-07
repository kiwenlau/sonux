#!/usr/bin/env python3
"""生成 Support/Localizable.xcstrings 与 Support/AppShortcuts.xcstrings（String Catalog）。

用法：python3 tools/generate_xcstrings.py
Localizable 的键来自两处：
① 代码里的 L("…") / LF("…") 字面量（自动扫描，防止表和代码脱节）；
② App Intents 的标题、参数名、摘要 —— 那些句子不经 L()（系统要在编译期读它们），
   所以列在 INTENT_KEYS 里，主函数会回查 Intents/*.swift 确认字面量还一模一样。
AppShortcuts 那几句说法（SHORTCUT_KEYS）不进 catalog：iOS 16 只读经典的
Support/AppShortcuts/<语言>.lproj/AppShortcuts.strings，所以单独逐语言落文件。
表里缺任何代码里用到的键、或多出代码里没有的键，都会报错退出。
源语言 en（键即英文原文），下面 TR 给其余 32 种语言的译文。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# kwargs 简名 → 语言代码（覆盖 iOS 给第三方 App 开放的语言清单，pt 分两站）
LANGS = {
    "ar": "ar", "ca": "ca", "hr": "hr", "cs": "cs", "da": "da", "nl": "nl",
    "fr": "fr", "de": "de", "el": "el", "he": "he", "hi": "hi", "hu": "hu",
    "id": "id", "it": "it", "ja": "ja", "ko": "ko", "ms": "ms", "nb": "nb",
    "pl": "pl", "ptbr": "pt-BR", "ptpt": "pt-PT", "ro": "ro", "ru": "ru",
    "sk": "sk", "es": "es", "sv": "sv", "th": "th", "tr": "tr", "uk": "uk",
    "vi": "vi", "zhhs": "zh-Hans", "zhtt": "zh-Hant",
}

TR: dict[str, dict[str, str]] = {}

def add(key: str, **langs):
    unknown = set(langs) - set(LANGS)
    if unknown:
        sys.exit(f"未知语言 kwargs: {unknown}")
    # 同一个键可多次 add（补翻时只给缺的语言），合并累加
    entry = TR.setdefault(key, {})
    entry.update({LANGS[k]: v for k, v in langs.items()})
    missing = set(LANGS.values()) - set(entry)
    if missing:
        print(f"提醒：键 {key!r} 暂缺 {sorted(missing)}（未补前该语言回退显示英文）")

# ---------------- 翻译表 ----------------

add("Audio", ar="الصوتيات", ca="Àudio", hr="Audio", cs="Audio", da="Lyd", nl="Audio",
    fr="Audio", de="Audio", el="Ήχος", he="אודיו", hi="ऑडियो", hu="Hang", id="Audio",
    it="Audio", ja="オーディオ", ko="오디오", ms="Audio", nb="Lyd", pl="Audio",
    ptbr="Áudio", ptpt="Áudio", ro="Audio", ru="Аудио", sk="Audio", es="Audio",
    sv="Ljud", th="เสียง", tr="Ses", uk="Аудіо", vi="Âm thanh", zhhs="音频", zhtt="音訊")

add("History", ar="السجل", ca="Historial", hr="Povijest", cs="Historie", da="Historik",
    nl="Geschiedenis", fr="Historique", de="Verlauf", el="Ιστορικό", he="היסטוריה",
    hi="इतिहास", hu="Előzmények", id="Riwayat", it="Cronologia", ja="履歴", ko="기록",
    ms="Sejarah", nb="Historikk", pl="Historia", ptbr="Histórico", ptpt="Histórico",
    ro="Istoric", ru="История", sk="História", es="Historial", sv="Historik",
    th="ประวัติ", tr="Geçmiş", uk="Історія", vi="Lịch sử", zhhs="历史", zhtt="歷史")

add("Me", ar="أنا", ca="Jo", hr="Ja", cs="Já", da="Jeg", nl="Ik", fr="Moi", de="Ich",
    el="Εγώ", he="אני", hi="मैं", hu="Én", id="Saya", it="Io", ja="マイ", ko="내",
    ms="Saya", nb="Meg", pl="Ja", ptbr="Eu", ptpt="Eu", ro="Eu", ru="Я", sk="Ja",
    es="Yo", sv="Jag", th="ฉัน", tr="Ben", uk="Я", vi="Tôi", zhhs="我的", zhtt="我的")

add("No Listening Records Yet", ar="لا توجد سجلات استماع بعد", ca="Encara no hi ha registres d'escolta",
    hr="Još nema zapisa slušanja", cs="Zatím žádné záznamy o poslechu", da="Ingen lyttehistorik endnu",
    nl="Nog geen luistergegevens", fr="Aucune écoute pour le moment", de="Noch keine Hördaten",
    el="Καμία εγγραφή ακρόασης", he="אין עדיין רשומות האזנה", hi="अभी कोई सुनने का रिकॉर्ड नहीं",
    hu="Még nincs hallgatási adat", id="Belum ada riwayat mendengarkan", it="Ancora nessun dato di ascolto",
    ja="まだ再生記録がありません", ko="아직 재생 기록이 없습니다", ms="Belum ada rekod pendengaran",
    nb="Ingen lyttehistorikk ennå", pl="Brak danych o słuchaniu", ptbr="Nenhum histórico de escuta ainda",
    ptpt="Ainda sem registos de escuta", ro="Nicio înregistrare de ascultare", ru="Нет данных о прослушивании",
    sk="Zatiaľ žiadne záznamy o počúvaní", es="Aún no hay historial de escucha", sv="Ingen lyssningshistorik ännu",
    th="ยังไม่มีบันทึกการฟัง", tr="Henüz dinleme kaydı yok", uk="Немає записів прослуховування",
    vi="Chưa có bản ghi nghe nào", zhhs="还没有收听记录", zhtt="還沒有收聽記錄")

add("Total Listening", ar="إجمالي الاستماع", ca="Escolta total", hr="Ukupno slušano",
    cs="Celkem poslechu", da="Samlet lyttetid", nl="Totale luistertijd", fr="Écoute totale",
    de="Gesamthörzeit", el="Σύνολο ακρόασης", he="סך ההאזנה", hi="कुल सुनना", hu="Összes hallgatás",
    id="Total waktu mendengarkan", it="Ascolto totale", ja="総再生時間", ko="총 재생 시간",
    ms="Jumlah pendengaran", nb="Total lyttetid", pl="Łączny czas słuchania", ptbr="Escuta total",
    ptpt="Tempo total de escuta", ro="Total ascultări", ru="Всего прослушано", sk="Celkový čas počúvania",
    es="Escucha total", sv="Total lyssningstid", th="ฟังทั้งหมด", tr="Toplam dinleme",
    uk="Загалом прослухано", vi="Tổng thời gian nghe", zhhs="累计收听", zhtt="累計收聽")

add("Today", ar="اليوم", ca="Avui", hr="Danas", cs="Dnes", da="I dag", nl="Vandaag",
    fr="Aujourd'hui", de="Heute", el="Σήμερα", he="היום", hi="आज", hu="Ma", id="Hari ini",
    it="Oggi", ja="今日", ko="오늘", ms="Hari ini", nb="I dag", pl="Dziś", ptbr="Hoje",
    ptpt="Hoje", ro="Astăzi", ru="Сегодня", sk="Dnes", es="Hoy", sv="Idag", th="วันนี้",
    tr="Bugün", uk="Сьогодні", vi="Hôm nay", zhhs="今天", zhtt="今天")

add("Last 7 Days", ar="آخر 7 أيام", ca="Els últims 7 dies", hr="Posljednjih 7 dana",
    cs="Posledních 7 dní", da="Sidste 7 dage", nl="Afgelopen 7 dagen", fr="7 derniers jours",
    de="Letzte 7 Tage", el="Τελευταίες 7 ημέρες", he="7 הימים האחרונים", hi="पिछले 7 दिन",
    hu="Az elmúlt 7 nap", id="7 hari terakhir", it="Ultimi 7 giorni", ja="過去 7 日間", ko="최근 7일",
    ms="7 hari lepas", nb="Siste 7 dager", pl="Ostatnie 7 dni", ptbr="Últimos 7 dias",
    ptpt="Últimos 7 dias", ro="Ultimele 7 zile", ru="Последние 7 дней", sk="Posledných 7 dní",
    es="Últimos 7 días", sv="Senaste 7 dagarna", th="7 วันที่ผ่านมา", tr="Son 7 gün",
    uk="Останні 7 днів", vi="7 ngày qua", zhhs="近 7 天", zhtt="近 7 天")

add("Listening Streak", ar="أيام متتالية", ca="Ratxa d'escolta", hr="Niz slušanja",
    cs="Série v poslechu", da="Række", nl="Luisterreeks", fr="Série d'écoute", de="Hörserie",
    el="Συνεχόμενη ακρόαση", he="רצף האזנה", hi="लगातार सुनना", hu="Hallgatási sorozat",
    id="Seri mendengarkan", it="Serie di ascolto", ja="連続再生日数", ko="연속 듣기",
    ms="Berturut-turut mendengar", nb="Rekke", pl="Seria słuchania", ptbr="Sequência de escuta",
    ptpt="Sequência de escuta", ro="Serie de ascultări", ru="Серия прослушиваний",
    sk="Séria v počúvaní", es="Racha de escucha", sv="Rekord", th="ฟังต่อเนื่อง",
    tr="Seri", uk="Серія прослуховувань", vi="Chuỗi ngày nghe", zhhs="连续收听", zhtt="連續收聽")

add("%d days", ar="%d أيام", ca="%d dies", hr="%d dana", cs="%d dní", da="%d dage",
    nl="%d dagen", fr="%d jours", de="%d Tage", el="%d ημέρες", he="%d ימים", hi="%d दिन",
    hu="%d nap", id="%d hari", it="%d giorni", ja="%d 日", ko="%d일", ms="%d hari",
    nb="%d dager", pl="%d dni", ptbr="%d dias", ptpt="%d dias", ro="%d zile", ru="%d дн.",
    sk="%d dní", es="%d días", sv="%d dagar", th="%d วัน", tr="%d gün", uk="%d днів",
    vi="%d ngày", zhhs="%d 天", zhtt="%d 天")

add('Works by "%@" Are No Longer in the Library',
    ar="أعمال «%@» لم تعد في المكتبة", ca="Les obres de «%@» ja no són a la biblioteca",
    hr="Djela «%@» više nisu u knjižnici", cs="Díla od «%@» nejsou ve knihovně",
    da="Værker af \"%@\" er ikke længere i biblioteket", nl="Werken van \"%@\" zijn niet meer in de bibliotheek",
    fr="Les œuvres de « %@ » ne sont plus dans la bibliothèque", de="Werke von \"%@\" sind nicht mehr in der Mediathek",
    el="Τα έργα του \"%@\" δεν υπάρχουν πλέον στη βιβλιοθήκη", he="היצירות של \"%@\" אינן עוד בספרייה",
    hi="\"%@\" की रचनाएँ अब लाइब्रेरी में नहीं हैं", hu="\"%@\" művei már nem találhatók a könyvtárban",
    id="Karya \"%@\" tidak ada lagi di Pustaka", it="Le opere di \"%@\" non sono più nella libreria",
    ja="「%@」の作品はライブラリにありません", ko="%@의 작품이 라이브러리에 없습니다",
    ms="Karya \"%@\" tiada lagi dalam Pustaka", nb="Verk av \"%@\" er ikke lenger i biblioteket",
    pl="Utwory «%@» nie są już w bibliotece", ptbr="As obras de \"%@\" não estão mais na biblioteca",
    ptpt="As obras de \"%@\" já não estão na biblioteca", ro="Lucrările lui \"%@\" nu mai sunt în Bibliotecă",
    ru="Произведения «%@» больше нет в библиотеке", sk="Diela od «%@» nie sú v knižnici",
    es="Las obras de «%@» ya no están en la biblioteca", sv="Verken av \"%@\" finns inte kvar i biblioteket",
    th="ผลงานของ \"%@\" ไม่อยู่ในคลังแล้ว", tr="\"%@\" adlı yazarın eserleri artık kütüphanede değil",
    uk="Твори «%@» більше немає в бібліотеці", vi="Các tác phẩm của \"%@\" không còn trong Thư viện",
    zhhs="「%@」的作品已不在书库", zhtt="「%@」的作品已不在書庫")

add("Delete", ar="حذف", ca="Elimina", hr="Obriši", cs="Smazat", da="Slet", nl="Verwijderen",
    fr="Supprimer", de="Löschen", el="Διαγραφή", he="מחיקה", hi="हटाएं", hu="Törlés",
    id="Hapus", it="Elimina", ja="削除", ko="삭제", ms="Padam", nb="Slett", pl="Usuń",
    ptbr="Apagar", ptpt="Apagar", ro="Șterge", ru="Удалить", sk="Odstrániť", es="Eliminar",
    sv="Radera", th="ลบ", tr="Sil", uk="Видалити", vi="Xóa", zhhs="删除", zhtt="刪除")

add("Import Finished", ar="اكتمل الاستيراد", ca="Importació completada", hr="Uvoz završen",
    cs="Import dokončen", da="Importering fuldført", nl="Import voltooid", fr="Import terminé",
    de="Import abgeschlossen", el="Η εισαγωγή ολοκληρώθηκε", he="הייבוא הושלם", hi="आयात पूरा हुआ",
    hu="Az importálás kész", id="Impor selesai", it="Importazione completata", ja="インポート完了",
    ko="가져오기 완료", ms="Import selesai", nb="Importering fullført", pl="Importowanie zakończone",
    ptbr="Importação concluída", ptpt="Importação concluída", ro="Importare finalizată",
    ru="Импорт завершён", sk="Import dokončený", es="Importación completada", sv="Importen slutförd",
    th="นำเข้าเสร็จแล้ว", tr="İçe aktarma tamamlandı", uk="Імпорт завершено",
    vi="Đã nhập xong", zhhs="导入完成", zhtt="匯入完成")

add("OK", ar="موافق", ca="D'acord", hr="U redu", cs="OK", da="OK", nl="OK", fr="OK",
    de="OK", el="Εντάξει", he="אישור", hi="ठीक है", hu="OK", id="OK", it="OK", ja="OK",
    ko="확인", ms="OK", nb="OK", pl="OK", ptbr="OK", ptpt="OK", ro="OK", ru="ОК", sk="OK",
    es="Aceptar", sv="OK", th="ตกลง", tr="Tamam", uk="ОК", vi="OK", zhhs="好", zhtt="好")

add('Delete "%@"', ar="حذف \"%@\"", ca="Elimina \"%@\"", hr="Obriši \"%@\"",
    cs="Smazat \"%@\"", da="Slet \"%@\"", nl="\"%@\" verwijderen", fr="Supprimer « %@ »",
    de="\"%@\" löschen", el="Διαγραφή \"%@\"", he="מחיקת \"%@\"", hi="\"%@\" हटाएं",
    hu="\"%@\" törlése", id="Hapus \"%@\"", it="Elimina \"%@\"", ja="「%@」を削除",
    ko="\"%@\" 삭제", ms="Padam \"%@\"", nb="Slett \"%@\"", pl="Usuń „%@”",
    ptbr="Apagar \"%@\"", ptpt="Apagar \"%@\"", ro="Șterge \"%@\"", ru="Удалить «%@»",
    sk="Odstrániť \"%@\"", es="Eliminar «%@»", sv="Radera \"%@\"", th="ลบ \"%@\"",
    tr="\"%@\" sil", uk="Видалити «%@»", vi="Xóa \"%@\"", zhhs="删除「%@」", zhtt="刪除「%@」")

add("Cancel", ar="إلغاء", ca="Cancel·la", hr="Odustani", cs="Zrušit", da="Annuller",
    nl="Annuleren", fr="Annuler", de="Abbrechen", el="Ακύρωση", he="ביטול", hi="रद्द करें",
    hu="Mégse", id="Batalkan", it="Annulla", ja="キャンセル", ko="취소", ms="Batal",
    nb="Avbryt", pl="Anuluj", ptbr="Cancelar", ptpt="Cancelar", ro="Anulează", ru="Отмена",
    sk="Zrušiť", es="Cancelar", sv="Avbryt", th="ยกเลิก", tr="Vazgeç", uk="Скасувати",
    vi="Hủy", zhhs="取消", zhtt="取消")

add("This will remove the audio files from your library. This action can't be undone.",
    ar="ستتم إزالة ملفات الصوت من المكتبة. لا يمكن التراجع عن هذا الإجراء.",
    ca="Es retirarà el fitxer d'àudio de la biblioteca. Aquesta acció no es pot desfer.",
    hr="Zvučna datoteka bit će uklonjena iz knjižnice. Ovu radnju nije moguće poništiti.",
    cs="Zvukový soubor bude z knihovny odebrán. Tuto akci nelze vrátit.",
    da="Lydfilen fjernes fra biblioteket. Handlingen kan ikke fortrydes.",
    nl="Het audiobestand wordt uit de bibliotheek verwijderd. Dit kan niet ongedaan worden gemaakt.",
    fr="Cette action retire le fichier audio de la bibliothèque. Elle ne peut pas être annulée.",
    de="Die Audiodatei wird aus der Mediathek entfernt. Dieser Vorgang kann nicht rückgängig gemacht werden.",
    el="Το αρχείο ήχου θα αφαιρεθεί από τη βιβλιοθήκη. Η ενέργεια δεν μπορεί να αναιρεθεί.",
    he="קובץ השמע יוסר מהספרייה. לא ניתן לבטל פעולה זו.",
    hi="ऑडियो फ़ाइल लाइब्रेरी से हटा दी जाएगी। यह क्रिया पूर्ववत नहीं की जा सकती।",
    hu="A hangfájl törlésre kerül a könyvtárból. A művelet nem vonható vissza.",
    id="File audio akan dihapus dari Pustaka. Tindakan ini tidak dapat dibatalkan.",
    it="Il file audio verrà rimosso dalla libreria. L'operazione non può essere annullata.",
    ja="このオーディオファイルをライブラリから削除します。この操作は取り消せません。",
    ko="이 오디오 파일을 라이브러리에서 제거합니다. 되돌릴 수 없습니다.",
    ms="Fail audio akan dialih keluar daripada Pustaka. Tindakan ini tidak boleh dibuat asal.",
    nb="Lydfilen fjernes fra biblioteket. Denne handlingen kan ikke angres.",
    pl="Plik audio zostanie usunięty z biblioteki. Tej operacji nie można cofnąć.",
    ptbr="O arquivo de áudio será removido da biblioteca. Esta ação não pode ser desfeita.",
    ptpt="O ficheiro de áudio será removido da biblioteca. Esta ação não pode ser reposta.",
    ro="Fișierul audio va fi eliminat din Bibliotecă. Acțiunea nu poate fi anulată.",
    ru="Аудиофайл будет удалён из библиотеки. Это действие необратимо.",
    sk="Zvukový súbor bude odstránený z knižnice. Túto akciu nemožno vrátiť.",
    es="El archivo de audio se eliminará de la biblioteca. Esta acción no se puede deshacer.",
    sv="Ljudfilen tas bort från biblioteket. Åtgärden kan inte ångras.",
    th="ไฟล์เสียงจะถูกลบออกจากคลัง การกระทำนี้ไม่สามารถย้อนกลับได้",
    tr="Ses dosyası kütüphaneden kaldırılacak. Bu işlem geri alınamaz.",
    uk="Аудіофайл буде вилучено з бібліотеки. Цю дію неможливо скасувати.",
    vi="Tệp âm thanh sẽ bị loại khỏi Thư viện. Hành động này không thể hoàn tác.",
    zhhs="将从书库中移除该音频文件，此操作不可撤销。", zhtt="將從書庫中移除該音訊檔案，此操作無法復原。")

add("This will remove the reference from your library. The audio files stay where they are.",
    ar="ستتم إزالة المرجع من المكتبة. ملفات الصوت تبقى في مكانها.",
    ca="S'eliminarà la referència de la biblioteca. Els fitxers d'àudio romanen on són.",
    hr="Referenca će se ukloniti iz knjižnice. Zvučne datoteke ostaju na mjestu.",
    cs="Odkaz bude z knihovny odebrán. Zvukové soubory zůstanou na místě.",
    da="Referencen fjernes fra biblioteket. Lydfilerne bliver liggende.",
    nl="De verwijzing wordt uit de bibliotheek verwijderd. De audiobestanden blijven liggen.",
    fr="La référence sera retirée de la bibliothèque. Les fichiers audio restent en place.",
    de="Der Verweis wird aus der Mediathek entfernt. Die Audiodateien bleiben an ihrem Platz.",
    el="Η αναφορά θα αφαιρεθεί από τη βιβλιοθήκη. Τα αρχεία ήχου παραμένουν στη θέση τους.",
    he="ההפניה תוסר מהספרייה. קובצי השמע נשארים במקומם.",
    hi="संदर्भ लाइब्रेरी से हटा दिया जाएगा। ऑडियो फ़ाइलें अपने स्थान पर रहेंगी।",
    hu="A hivatkozás eltávolításra kerül a könyvtárból. A hangfájlok helyükön maradnak.",
    id="Referensi akan dihapus dari Pustaka. Berkas audio tetap di tempatnya.",
    it="Il riferimento verrà rimosso dalla libreria. I file audio restano dove sono.",
    ja="参照がライブラリから削除されます。音声ファイルは元の場所にそのまま残ります。",
    ko="참조가 라이브러리에서 제거됩니다. 오디오 파일은 원래 자리에 그대로 있습니다.",
    ms="Rujukan akan dialih keluar daripada Pustaka. Fail audio kekal di tempatnya.",
    nb="Referansen fjernes fra biblioteket. Lydfilene blir hvor de er.",
    pl="Odwołanie zostanie usunięte z biblioteki. Pliki audio pozostaną na miejscu.",
    ptbr="A referência será removida da biblioteca. Os arquivos de áudio continuam onde estão.",
    ptpt="A referência será removida da biblioteca. Os ficheiros de áudio continuam onde estão.",
    ro="Referința va fi eliminată din Bibliotecă. Fișierele audio rămân unde sunt.",
    ru="Ссылка будет удалена из библиотеки. Аудиофайлы останутся на месте.",
    sk="Odkaz bude odstránený z knižnice. Zvukové súbory zostanú na mieste.",
    es="La referencia se quitará de la biblioteca. Los archivos de audio siguen donde están.",
    sv="Referensen tas bort från biblioteket. Ljudfilerna ligger kvar där de är.",
    th="การอ้างอิงนี้จะถูกลบจากคลัง แต่ไฟล์เสียงยังอยู่ที่เดิม",
    tr="Bağlantı kütüphaneden kaldırılacak. Ses dosyaları yerlerinde kalır.",
    uk="Посилання буде вилучено з бібліотеки. Аудіофайли залишаться на місці.",
    vi="Tham chiếu sẽ bị xóa khỏi Thư viện. Tệp âm thanh vẫn ở nguyên chỗ cũ.",
    zhhs="只会从书库中移除该引用，音频文件仍在原处。", zhtt="只會從書庫中移除該參照，音訊檔案仍在原處。")

add("Delete Failed", ar="تعذر الحذف", ca="Error en eliminar", hr="Brisanje nije uspjelo",
    cs="Odstranění se nezdařilo", da="Sletning mislykkedes", nl="Verwijderen mislukt",
    fr="Échec de la suppression", de="Löschen fehlgeschlagen", el="Η διαγραφή απέτυχε",
    he="המחיקה נכשלה", hi="हटाना विफल", hu="A törlés nem sikerült", id="Gagal menghapus",
    it="Eliminazione non riuscita", ja="削除失敗", ko="삭제 실패", ms="Gagal dipadam",
    nb="Sletting mislyktes", pl="Nie udało się usunąć", ptbr="Falha ao apagar",
    ptpt="Falha ao apagar", ro="Ștergere eșuată", ru="Не удалось удалить", sk="Odstránenie zlyhalo",
    es="Error al eliminar", sv="Radering misslyckades", th="ลบไม่สำเร็จ", tr="Silme başarısız",
    uk="Не вдалося видалити", vi="Xóa thất bại", zhhs="删除失败", zhtt="刪除失敗")

add("Nothing to import (supports m4a / m4b / mp3 / aac / wav, or folders containing these files)",
    ar="لا يوجد صوت للاستيراد (يدعم m4a / m4b / mp3 / aac / wav أو المجلدات التي تحتوي على هذه الملفات)",
    ca="No hi ha àudio per importar (admet m4a / m4b / mp3 / aac / wav o carpetes que continguin aquests fitxers)",
    hr="Nema audio zapisa za uvoz (podržani su m4a / m4b / mp3 / aac / wav ili mape koje sadrže te datoteke)",
    cs="Žádný audio k importu (podporuje m4a / m4b / mp3 / aac / wav nebo složky s těmito soubory)",
    da="Der er ingen lyd at importere (understøtter m4a / m4b / mp3 / aac / wav eller mapper med disse filer)",
    nl="Er is geen audio om te importeren (ondersteunt m4a / m4b / mp3 / aac / wav of mappen met deze bestanden)",
    fr="Aucun audio à importer (formats pris en charge : m4a / m4b / mp3 / aac / wav, ou dossiers contenant ces fichiers)",
    de="Keine Audiodateien zum Importieren (unterstützt m4a / m4b / mp3 / aac / wav oder Ordner mit diesen Dateien)",
    el="Δεν υπάρχει ήχος για εισαγωγή (υποστηρίζει m4a / m4b / mp3 / aac / wav ή φακέλους με αυτά τα αρχεία)",
    he="אין אודיו לייבוא (תומך ב־m4a / m4b / mp3 / aac / wav או בתיקיות המכילות קבצים אלה)",
    hi="आयात करने के लिए कोई ऑडियो नहीं (m4a / m4b / mp3 / aac / wav या इन फ़ाइलों वाले फ़ोल्डर समर्थित)",
    hu="Nincs importálható hang (m4a / m4b / mp3 / aac / wav vagy ezeket tartalmazó mappák támogatottak)",
    id="Tidak ada audio untuk diimpor (mendukung m4a / m4b / mp3 / aac / wav, atau folder berisi file-file ini)",
    it="Nessun audio da importare (supporta m4a / m4b / mp3 / aac / wav o cartelle contenenti questi file)",
    ja="インポートできるオーディオがありません（m4a / m4b / mp3 / aac / wav、またはこれらのファイルを含むフォルダに対応）",
    ko="가져올 오디오가 없습니다(m4a / m4b / mp3 / aac / wav 또는 해당 파일을 포함하는 폴더 지원)",
    ms="Tiada audio untuk diimport (menyokong m4a / m4b / mp3 / aac / wav atau folder yang mengandungi fail ini)",
    nb="Det er ingen lyd å importere (støtter m4a / m4b / mp3 / aac / wav eller mapper med disse filene)",
    pl="Brak audio do zaimportowania (obsługiwane m4a / m4b / mp3 / aac / wav lub foldery zawierające te pliki)",
    ptbr="Nenhum áudio para importar (compatível com m4a / m4b / mp3 / aac / wav ou pastas que contenham esses arquivos)",
    ptpt="Nenhum áudio para importar (suporta m4a / m4b / mp3 / aac / wav ou pastas que contenham estes ficheiros)",
    ro="Nu există audio de importat (suportă m4a / m4b / mp3 / aac / wav sau foldere cu aceste fișiere)",
    ru="Нет аудио для импорта (поддерживаются m4a / m4b / mp3 / aac / wav или папки с этими файлами)",
    sk="Žiadny audio na import (podporuje m4a / m4b / mp3 / aac / wav alebo priečinky s týmito súbormi)",
    es="No hay audio para importar (compatible con m4a / m4b / mp3 / aac / wav o carpetas que contengan estos archivos)",
    sv="Det finns ingen ljud att importera (stöder m4a / m4b / mp3 / aac / wav eller mappar med dessa filer)",
    th="ไม่มีเสียงสำหรับนำเข้า (รองรับ m4a / m4b / mp3 / aac / wav หรือโฟลเดอร์ที่มีไฟล์เหล่านี้)",
    tr="İçe aktarılacak ses yok (m4a / m4b / mp3 / aac / wav veya bu dosyaları içeren klasörleri destekler)",
    uk="Немає аудіо для імпорту (підтримуються m4a / m4b / mp3 / aac / wav або папки з цими файлами)",
    vi="Không có gì để nhập (hỗ trợ m4a / m4b / mp3 / aac / wav hoặc thư mục chứa các tệp này)",
    zhhs="没有可导入的音频（支持 m4a / m4b / mp3 / aac / wav 或含这些文件的文件夹）",
    zhtt="沒有可匯入的音訊（支援 m4a / m4b / mp3 / aac / wav 或含這些檔案的資料夾）")

add("Imported %d items", ar="تم استيراد %d عنصرًا", ca="%d elements importats", hr="Uvezeno %d stavki",
    cs="Importováno %d položek", da="%d elementer importeret", nl="%d items geïmporteerd",
    fr="%d éléments importés", de="%d Objekte importiert", el="Εισήχθησαν %d στοιχεία",
    he="יובאו %d פריטים", hi="%d आइटम आयात किए", hu="%d elem importálva", id="%d item diimpor",
    it="%d elementi importati", ja="%d 項目をインポートしました", ko="%d개 항목 가져오기 완료",
    ms="%d item diimport", nb="%d elementer importert", pl="Zaimportowano %d elementów",
    ptbr="%d itens importados", ptpt="%d itens importados", ro="%d elemente importate",
    ru="Импортировано: %d", sk="Importovaných %d položiek", es="%d elementos importados",
    sv="%d objekt importerades", th="นำเข้าแล้ว %d รายการ", tr="%d öğe içe aktarıldı",
    uk="Імпортовано: %d", vi="Đã nhập %d mục", zhhs="已导入 %d 项", zhtt="已匯入 %d 項")

add("Import Failed, Please Try Again", ar="تعذر الاستيراد. حاول مرة أخرى",
    ca="La importació ha fallat, torneu-ho a provar", hr="Uvoz nije uspio, pokušajte ponovno",
    cs="Import se nezdařil, zkuste to znovu", da="Importeringen fejlede, prøv igen",
    nl="Importeren mislukt, probeer het opnieuw", fr="Échec de l'import. Veuillez réessayer",
    de="Import fehlgeschlagen, bitte erneut versuchen", el="Η εισαγωγή απέτυχε, δοκιμάστε ξανά",
    he="הייבוא נכשל, נסו שוב", hi="आयात विफल, कृपया पुनः प्रयास करें", hu="Az importálás nem sikerült, próbálja újra",
    id="Impor gagal, coba lagi", it="Importazione non riuscita, riprova", ja="インポートに失敗しました。もう一度お試しください",
    ko="가져오기에 실패했습니다. 다시 시도해 주세요", ms="Import gagal, cuba lagi",
    nb="Importeringen mislyktes, prøv på nytt", pl="Import nie powiódł się, spróbuj ponownie",
    ptbr="Falha na importação. Tente novamente", ptpt="Falha na importação. Tente novamente",
    ro="Importare eșuată, încercați din nou", ru="Не удалось импортировать. Повторите попытку",
    sk="Import zlyhal, skúste znova", es="Error al importar. Inténtelo de nuevo",
    sv="Importen misslyckades, försök igen", th="นำเข้าล้มเหลว กรุณาลองอีกครั้ง",
    tr="İçe aktarma başarısız, tekrar deneyin", uk="Не вдалося імпортувати, спробуйте ще раз",
    vi="Nhập thất bại, vui lòng thử lại", zhhs="导入失败，请重试", zhtt="匯入失敗，請重試")

add('Play "%@" from Where You Left Off',
    ar="شغّل \"%@\" من حيث توقفت", ca="Reprodueix \"%@\" des d'on ho vas deixar",
    hr="Reproduciraj \"%@\" od mjesta zaustavljanja", cs="Přehrát \"%@\" tam, kde jste skončili",
    da="Afspil \"%@\" hvor du slap", nl="\"%@\" afspelen waar je gebleven was",
    fr="Lire « %@ » où vous étiez", de="\"%@\" fortsetzen", el="Αναπαραγωγή του \"%@\" από εκεί που σταματήσατε",
    he="נגן את \"%@\" מאותה נקודה", hi="\"%@\" वहां से चलाएं जहां छोड़ा था", hu="\"%@\" lejátszása, ahol abbahagyta",
    id="Putar \"%@\" dari terakhir kali", it="Riproduci \"%@\" da dove eri rimasto", ja="「%@」を前回の位置から再生",
    ko="%@을(를) 마지막 위치부터 재생", ms="Main \"%@\" dari tempat anda berhenti", nb="Spill \"%@\" der du slapp",
    pl="Odtwórz „%@” od miejsca przerwania", ptbr="Reproduzir \"%@\" de onde parou",
    ptpt="Reproduzir \"%@\" de onde parou", ro="Redă \"%@\" de unde ai rămas", ru="Воспроизвести «%@» с места остановки",
    sk="Prehrať \"%@\" tam, kde ste skončili", es="Reproducir «%@» donde lo dejaste",
    sv="Spela \"%@\" där du slutade", th="เล่น \"%@\" ต่อจากที่หยุดไว้", tr="\"%@\" kaldığın yerden oynat",
    uk="Відтворити «%@» з місця зупинки", vi="Phát \"%@\" từ chỗ bạn dừng lại",
    zhhs="从上次位置播放《%@》", zhtt="從上次位置播放《%@》")

add('Open Details for "%@"',
    ar="افتح تفاصيل \"%@\"", ca="Obre els detalls de \"%@\"", hr="Otvori detalje \"%@\"",
    cs="Otevřít detaily „%@“", da="Åbn detaljer for \"%@\"", nl="Details van \"%@\" openen",
    fr="Ouvrir les détails de « %@ »", de="Details zu \"%@\" öffnen", el="Άνοιγμα λεπτομερειών \"%@\"",
    he="פתח פרטים של \"%@\"", hi="\"%@\" विवरण खोलें", hu="\"%@\" részleteinek megnyitása",
    id="Buka detail \"%@\"", it="Apri i dettagli di \"%@\"", ja="「%@」の詳細を開く",
    ko="%@ 세부 정보 열기", ms="Buka butiran \"%@\"", nb="Åpne detaljer for \"%@\"",
    pl="Otwórz szczegóły „%@”", ptbr="Abrir detalhes de \"%@\"", ptpt="Abrir detalhes de \"%@\"",
    ro="Deschide detaliile pentru \"%@\"", ru="Открыть сведения «%@»", sk="Otvoriť detaily „%@“",
    es="Abrir detalles de «%@»", sv="Öppna detaljer för \"%@\"", th="เปิดรายละเอียดของ \"%@\"",
    tr="\"%@\" ayrıntılarını aç", uk="Відкрити подробиці «%@»", vi="Mở chi tiết cho \"%@\"",
    zhhs="打开《%@》详情", zhtt="打開《%@》詳情")

add("Search Library", ar="ابحث في المكتبة", ca="Cerca a la biblioteca", hr="Pretraži knjižnicu",
    cs="Hledat v knihovně", da="Søg i biblioteket", nl="Bibliotheek doorzoeken",
    fr="Rechercher dans la bibliothèque", de="Mediathek durchsuchen", es="Buscar en la biblioteca",
    ptbr="Pesquisar na biblioteca", ptpt="Pesquisar na biblioteca", it="Cerca nella libreria",
    ru="Поиск в библиотеке", el="Αναζήτηση στη βιβλιοθήκη", he="חיפוש בספרייה", hi="लाइब्रेरी में खोजें",
    id="Cari di Pustaka", ms="Cari dalam Pustaka", nb="Søk i biblioteket",
    pl="Szukaj w bibliotece", ro="Caută în Bibliotecă", sk="Hľadať v knižnici", sv="Sök i biblioteket",
    th="ค้นหาในคลัง", tr="Kütüphanede ara", uk="Пошук у бібліотеці", vi="Tìm trong Thư viện",
    hu="Keresés a könyvtárban", ja="ライブラリを検索", ko="라이브러리 검색", zhhs="搜索书库", zhtt="搜尋書庫")

add("Clear Search Keywords", ar="مسح كلمات البحث", ca="Esborra les paraules clau", hr="Obriši ključne riječi",
    cs="Vymazat klíčová slova", da="Ryd søgeord", nl="Zoekwoorden wissen", fr="Effacer les mots-clés",
    de="Suchbegriffe löschen", el="Διαγραφή λέξεων-κλειδιών", he="נקה מילות חיפוש", hi="खोज शब्द साफ़ करें",
    hu="Keresőkulcsok törlése", id="Hapus kata kunci", it="Cancella parole chiave", ja="検索キーワードを消去",
    ko="검색어 지우기", ms="Kosongkan kata kunci", nb="Tøm søkeord", pl="Wyczyść słowa kluczowe",
    ptbr="Limpar termos de busca", ptpt="Limpar termos de pesquisa", ro="Golează cuvintele cheie",
    ru="Очистить ключевые слова", sk="Vymazať kľúčové slová", es="Borrar palabras clave",
    sv="Rensa sökord", th="ล้างคำค้นหา", tr="Arama terimlerini temizle", uk="Очистити ключові слова",
    vi="Xóa từ khóa tìm kiếm", zhhs="清空搜索关键词", zhtt="清空搜尋關鍵詞")

add('No Results for "%@"',
    ar="لا نتائج لـ \"%@\"", ca="Cap resultat per a \"%@\"", hr="Nema rezultata za \"%@\"",
    cs="Žádné výsledky pro \"%@\"", da="Ingen resultater for \"%@\"", nl="Geen resultaten voor \"%@\"",
    fr="Aucun résultat pour « %@ »", de="Keine Ergebnisse für \"%@\"", el="Κανένα αποτέλεσμα για \"%@\"",
    he="לא נמצאו תוצאות עבור \"%@\"", hi="\"%@\" के लिए कोई परिणाम नहीं", hu="Nincs találat: \"%@\"",
    id="Tidak ada hasil untuk \"%@\"", it="Nessun risultato per \"%@\"", ja="「%@」は見つかりませんでした",
    ko="%@에 대한 결과 없음", ms="Tiada hasil untuk \"%@\"", nb="Ingen resultater for \"%@\"",
    pl="Brak wyników dla „%@”", ptbr="Nenhum resultado para \"%@\"", ptpt="Sem resultados para \"%@\"",
    ro="Niciun rezultat pentru \"%@\"", ru="Нет результатов по «%@»", sk="Žiadne výsledky pre \"%@\"",
    es="Sin resultados para «%@»", sv="Inga resultat för \"%@\"", th="ไม่พบผลลัพธ์สำหรับ \"%@\"",
    tr="%@ için sonuç yok", uk="Немає результатів за запитом «%@»", vi="Không có kết quả cho \"%@\"",
    zhhs="没有找到「%@」", zhtt="沒有找到「%@」")

add("Loading Library", ar="جارٍ تحميل المكتبة", ca="S'està carregant la biblioteca", hr="Učitavanje knjižnice",
    cs="Načítání knihovny", da="Indlæser bibliotek", nl="Bibliotheek laden", fr="Chargement de la bibliothèque",
    de="Mediathek wird geladen", el="Φόρτωση βιβλιοθήκης", he="טוען את הספרייה", hi="लाइब्रेरी लोड हो रही है",
    hu="Könyvtár betöltése", id="Memuat pustaka", it="Caricamento libreria", ja="ライブラリを読み込み中",
    ko="라이브러리 불러오는 중", ms="Memuat pustaka", nb="Laster bibliotek", pl="Wczytywanie biblioteki",
    ptbr="Carregando biblioteca", ptpt="A carregar a biblioteca", ro="Se încarcă biblioteca",
    ru="Загрузка библиотеки", sk="Načítava sa knižnica", es="Cargando biblioteca", sv="Biblioteket laddas",
    th="กำลังโหลดคลัง", tr="Kütüphane yükleniyor", uk="Завантаження бібліотеки", vi="Đang tải thư viện",
    zhhs="正在载入书库", zhtt="正在載入書庫")

add("Library Is Empty", ar="المكتبة فارغة", ca="La biblioteca és buida", hr="Knjižnica je prazna",
    cs="Knihovna je prázdná", da="Biblioteket er tomt", nl="De bibliotheek is leeg", fr="La bibliothèque est vide",
    de="Die Mediathek ist leer", el="Η βιβλιοθήκη είναι άδεια", he="הספרייה ריקה", hi="लाइब्रेरी खाली है",
    hu="A könyvtár üres", id="Pustaka kosong", it="La libreria è vuota", ja="ライブラリは空です",
    ko="라이브러리가 비어 있습니다", ms="Pustaka kosong", nb="Biblioteket er tomt", pl="Biblioteka jest pusta",
    ptbr="A biblioteca está vazia", ptpt="A biblioteca está vazia", ro="Biblioteca este goală",
    ru="Библиотека пуста", sk="Knižnica je prázdna", es="La biblioteca está vacía", sv="Biblioteket är tomt",
    th="คลังว่างเปล่า", tr="Kütüphane boş", uk="Бібліотека порожня", vi="Thư viện trống",
    zhhs="书库是空的", zhtt="書庫是空的")

add("Import Audio", ar="استيراد الصوت", ca="Importa àudio", hr="Uvezi audio", cs="Importovat audio",
    da="Importer lyd", nl="Audio importeren", fr="Importer un fichier audio", de="Audiodateien importieren",
    el="Εισαγωγή ήχου", he="ייבוא אודיו", hi="ऑडियो आयात करें", hu="Audio importálása", id="Impor audio",
    it="Importa audio", ja="オーディオをインポート", ko="오디오 가져오기", ms="Import audio",
    nb="Importer lyd", pl="Importuj audio", ptbr="Importar áudio", ptpt="Importar áudio",
    ro="Importă audio", ru="Импортировать аудио", sk="Importovať audio", es="Importar audio",
    sv="Importera ljud", th="นำเข้าเสียง", tr="Ses içe aktar", uk="Імпортувати аудіо",
    vi="Nhập âm thanh", zhhs="导入音频", zhtt="匯入音訊")

add("Rescan", ar="أعد المسح", ca="Torna a escanejar", hr="Skeniraj ponovno", cs="Znovu skenovat",
    da="Scan igen", nl="Opnieuw scannen", fr="Rescanner", de="Erneut scannen", el="Εκ νέου σάρωση",
    he="סריקה מחדש", hi="फिर से स्कैन करें", hu="Újraolvasás", id="Pindai ulang", it="Scansiona di nuovo",
    ja="再スキャン", ko="다시 스캔", ms="Imbas semula", nb="Skann på nytt", pl="Skanuj ponownie",
    ptbr="Reescanear", ptpt="Voltar a analisar", ro="Rescanează", ru="Повторить сканирование",
    sk="Znovu skenovať", es="Volver a escanear", sv="Skanna igen", th="สแกนใหม่", tr="Yeniden tara",
    uk="Сканувати повторно", vi="Quét lại", zhhs="重新扫描", zhtt="重新掃描")

add("Reset Progress", ar="إعادة تعيين التقدم", ca="Reinicia el progrés", hr="Poništi napredak",
    cs="Obnovit průběh", da="Nulstil forløb", nl="Voortgang resetten", fr="Réinitialiser la progression",
    de="Fortschritt zurücksetzen", el="Επαναφορά προόδου", he="איפוס התקדמות", hi="प्रगति रीसेट करें",
    hu="Haladás alaphelyzetbe", id="Setel ulang kemajuan", it="Azzera avanzamento", ja="再生位置をリセット",
    ko="진행 상황 재설정", ms="Set semula kemajuan", nb="Tilbakestill fremdrift", pl="Zresetuj postęp",
    ptbr="Reiniciar progresso", ptpt="Repor o progresso", ro="Resetează progresul", ru="Сбросить прогресс",
    sk="Obnoviť priebeh", es="Restablecer progreso", sv="Återställ framsteg", th="รีเซ็ตความคืบหน้า",
    tr="İlerlemeyi sıfırla", uk="Скинути прогрес", vi="Đặt lại tiến độ", zhhs="重置进度", zhtt="重設進度")

add('View All Books by "%@"',
    ar="عرض كل كتب \"%@\"", ca="Veure tots els llibres de \"%@\"", hr="Prikaži sve knjige autora \"%@\"",
    cs="Zobrazit všechny knihy od \"%@\"", da="Se alle bøger af \"%@\"", nl="Alle boeken van \"%@\" bekijken",
    fr="Voir tous les livres de « %@ »", de="Alle Bücher von \"%@\" anzeigen", el="Προβολή όλων των βιβλίων του \"%@\"",
    he="הצג את כל הספרים של \"%@\"", hi="\"%@\" की सभी पुस्तकें देखें", hu="\"%@\" összes könyvének megtekintése",
    id="Lihat semua buku oleh \"%@\"", it="Vedi tutti i libri di \"%@\"", ja="「%@」のすべての作品を見る",
    ko="%@의 모든 도서 보기", ms="Lihat semua buku oleh \"%@\"", nb="Se alle bøker av \"%@\"",
    pl="Zobacz wszystkie książki „%@”", ptbr="Ver todos os livros de \"%@\"", ptpt="Ver todos os livros de \"%@\"",
    ro="Vezi toate cărțile lui \"%@\"", ru="Показать все книги «%@»", sk="Zobraziť všetky knihy od \"%@\"",
    es="Ver todos los libros de «%@»", sv="Visa alla böcker av \"%@\"", th="ดูหนังสือทั้งหมดของ \"%@\"",
    tr="\"%@\" adlı yazarın tüm kitaplarını gör", uk="Переглянути всі книги «%@»", vi="Xem mọi sách của \"%@\"",
    zhhs="查看作者「%@」的全部书籍", zhtt="檢視作者「%@」的全部書籍")

add("Finished", ar="مكتمل", ca="Escoltat", hr="Preslušano", cs="Poslechnuto", da="Færdig",
    nl="Voltooid", fr="Écouté", de="Abgeschlossen", el="Ολοκληρώθηκε", he="הושלם", hi="पूरा हुआ",
    hu="Elhallgatva", id="Selesai", it="Completato", ja="再生完了", ko="완료", ms="Selesai",
    nb="Fullført", pl="Ukończono", ptbr="Concluído", ptpt="Concluído", ro="Finalizat", ru="Прослушано",
    sk="Vypočuté", es="Escuchado", sv="Avklarad", th="ฟังจบแล้ว", tr="Bitti", uk="Прослухано",
    vi="Đã nghe xong", zhhs="已听完", zhtt="已聽完")

add("Now Playing", ar="يتم التشغيل الآن", ca="S'està reproduint", hr="Sada se reproducira",
    cs="Právě se přehrává", da="Afspiller nu", nl="Wordt nu afgespeeld", fr="Lecture en cours",
    de="Wird gerade abgespielt", el="Τώρα παίζει", he="מנגן כעת", hi="अभी चल रहा है", hu="Most szól",
    id="Sedang diputar", it="In riproduzione", ja="再生中", ko="재생 중", ms="Kini dimainkan",
    nb="Spilles nå", pl="Teraz odtwarzane", ptbr="Tocando agora", ptpt="A reproduzir agora",
    ro="Se redă acum", ru="Сейчас воспроизводится", sk="Práve sa prehráva", es="Reproduciendo ahora",
    sv="Spelas upp nu", th="กำลังเล่น", tr="Şimdi çalıyor", uk="Зараз відтворюється",
    vi="Đang phát", zhhs="正在播放", zhtt="正在播放")

add("No Listening History Yet", ar="لا يوجد سجل استماع بعد", ca="Encara no hi ha historial de reproducció",
    hr="Još nema povijesti reprodukcije", cs="Zatím žádná historie přehrávání", da="Ingen afspilningshistorik endnu",
    nl="Nog geen afspeelgeschiedenis", fr="Aucun historique d'écoute", de="Noch kein Wiedergabeverlauf",
    el="Κανένα ιστορικό ακρόασης ακόμα", he="אין היסטוריית האזנה עדיין", hi="अभी कोई प्लेबैक इतिहास नहीं",
    hu="Még nincs lejátszási előzmény", id="Belum ada riwayat pemutaran", it="Nessuno storico di riproduzione",
    ja="まだ再生履歴がありません", ko="재생 기록이 없습니다", ms="Belum ada sejarah mainan",
    nb="Ingen avspillingshistorikk ennå", pl="Brak historii odtwarzania", ptbr="Nenhum histórico de reprodução",
    ptpt="Ainda sem histórico de reprodução", ro="Niciun istoric de redare încă", ru="История прослушивания пуста",
    sk="Zatiaľ žiadna história prehrávania", es="Aún no hay historial de reproducción",
    sv="Ingen lyssningshistorik ännu", th="ยังไม่มีประวัติการเล่น", tr="Henüz dinleme geçmişi yok",
    uk="Історія прослуховування порожня", vi="Chưa có lịch sử phát nào", zhhs="还没有播放记录", zhtt="還沒有播放記錄")

add("Remove from History", ar="إزالة من السجل", ca="Suprimeix de l'historial", hr="Ukloni iz povijesti",
    cs="Odebrat z historie", da="Fjern fra historik", nl="Verwijderen uit geschiedenis",
    fr="Retirer de l'historique", de="Aus Verlauf entfernen", el="Κατάργηση από το ιστορικό",
    he="הסר מההיסטוריה", hi="इतिहास से हटाएं", hu="Eltávolítás az előzmények közül", id="Hapus dari riwayat",
    it="Rimuovi dallo storico", ru="Убрать из истории", sk="Odstrániť z histórie", es="Quitar del historial",
    ptbr="Remover do histórico", ptpt="Remover do histórico", sv="Ta bort från historiken", ro="Elimină din istoric",
    ja="履歴から削除", ko="기록에서 제거", ms="Alih keluar daripada sejarah", nb="Fjern fra historikk",
    pl="Usuń z historii", th="นำออกจากประวัติ", tr="Geçmişten kaldır", uk="Видалити з історії",
    vi="Xóa khỏi lịch sử", zhhs="从历史中移除", zhtt="從歷史中移除")

add("Not Started", ar="لم يبدأ", ca="Sense començar", hr="Nije započeto", cs="Nezačato", da="Ikke startet",
    nl="Niet gestart", fr="Pas commencé", de="Nicht gestartet", el="Δεν έχει ξεκινήσει", he="טרם החל",
    hi="शुरू नहीं हुआ", hu="Meg nem kezdődött", id="Belum dimulai", it="Non iniziato", ja="未再生",
    ko="시작하지 않음", ms="Belum dimulakan", nb="Ikke startet", pl="Nie rozpoczęto", ptbr="Não iniciado",
    ptpt="Ainda não iniciado", ro="Neînceput", ru="Не начато", sk="Nezačaté", es="Sin empezar",
    sv="Inte påbörjad", th="ยังไม่ได้เริ่ม", tr="Başlatılmadı", uk="Не розпочато", vi="Chưa bắt đầu",
    zhhs="未开始", zhtt="未開始")

add('Finished "%@"',
    ar="اكتمل \"%@\"", ca="\"%@\" escoltat", hr="\"%@\" preslušano", cs="\"%@\" poslechnuto",
    da="\"%@\" færdig", nl="\"%@\" voltooid", fr="« %@ » écouté", de="\"%@\" gehört",
    el="Ολοκληρώθηκε \"%@\"", he="%@ הושלם", hi="\"%@\" पूरा हुआ", hu="\"%@\" elhallgatva",
    id="\"%@\" selesai", it="\"%@\" completato", ja="「%@」を聞き終えました", ko="%@ 듣기 완료",
    ms="%@ selesai", nb="\"%@\" fullført", pl="\"%@\" ukończone", ptbr="\"%@\" concluído",
    ptpt="\"%@\" concluído", ro="%@ finalizat", ru="«%@» прослушано", sk="\"%@\" vypočuté",
    es="%@ escuchado", sv="\"%@\" avklarad", th="ฟัง \"%@\" จบแล้ว", tr="\"%@\" bitti",
    uk="«%@» прослухано", vi="Đã nghe xong \"%@\"", zhhs="已听完「%@」", zhtt="已聽完「%@」")

add("Today %@", ar="اليوم %@", ca="Avui %@", hr="Danas %@", cs="Dnes %@", da="I dag %@",
    nl="Vandaag %@", fr="Aujourd'hui %@", de="Heute %@", el="Σήμερα %@", he="היום %@", hi="आज %@",
    hu="Ma %@", id="Hari ini %@", it="Oggi %@", ja="今日 %@", ko="오늘 %@", ms="Hari ini %@",
    nb="I dag %@", pl="Dziś %@", ptbr="Hoje %@", ptpt="Hoje %@", ro="Astăzi %@", ru="Сегодня %@",
    sk="Dnes %@", es="Hoy %@", sv="Idag %@", th="วันนี้ %@", tr="Bugün %@", uk="Сьогодні %@",
    vi="Hôm nay %@", zhhs="今天 %@", zhtt="今天 %@")

add("Yesterday %@", ar="أمس %@", ca="Ahir %@", hr="Jučer %@", cs="Včera %@", da="I går %@",
    nl="Gisteren %@", fr="Hier %@", de="Gestern %@", el="Χθες %@", he="אתמול %@", hi="कल %@",
    hu="Tegnap %@", id="Kemarin %@", it="Ieri %@", ja="昨日 %@", ko="어제 %@", ms="Semalam %@",
    nb="I går %@", pl="Wczoraj %@", ptbr="Ontem %@", ptpt="Ontem %@", ro="Ieri %@", ru="Вчера %@",
    sk="Včera %@", es="Ayer %@", sv="I går %@", th="เมื่อวาน %@", tr="Dün %@", uk="Вчора %@",
    vi="Hôm qua %@", zhhs="昨天 %@", zhtt="昨天 %@")

add("Day Before Yesterday %@", ar="أول أمس %@", ca="Abans-d'ahir %@", hr="Prekjučer %@",
    cs="Předevčírem %@", da="I forgårs %@", nl="Eergisteren %@", fr="Avant-hier %@",
    de="Vorgestern %@", el="Πρόχθες %@", he="שלשום %@", hi="परसों %@", hu="Tegnapelőtt %@",
    id="Dua hari lalu %@", it="Avantieri %@", ja="おととい %@", ko="그제 %@", ms="Dua hari lalu %@",
    nb="I forgårs %@", pl="Przedwczoraj %@", ptbr="Anteontem %@", ptpt="Anteontem %@",
    ro="Alaltăieri %@", ru="Позавчера %@", sk="Predvčerom %@", es="Anteayer %@", sv="I förrgår %@",
    th="วันก่อน %@", tr="Evvelsi gün %@", uk="Позавчора %@", vi="Hôm kia %@",
    zhhs="前天 %@", zhtt="前天 %@")

add("Back", ar="رجوع", ca="Enrere", hr="Natrag", cs="Zpět", da="Tilbage", nl="Terug", fr="Retour",
    de="Zurück", el="Πίσω", he="חזרה", hi="वापस", hu="Vissza", id="Kembali", it="Indietro",
    ja="戻る", ko="뒤로", ms="Kembali", nb="Tilbake", pl="Wstecz", ptbr="Voltar", ptpt="Voltar",
    ro="Înapoi", ru="Назад", sk="Späť", es="Atrás", sv="Tillbaka", th="ย้อนกลับ", tr="Geri",
    uk="Назад", vi="Quay lại", zhhs="返回", zhtt="返回")

add("Not Playing", ar="غير قيد التشغيل", ca="No s'està reproduint", hr="Nije u reprodukciji",
    cs="Nepřehrává se", da="Afspiller ikke", nl="Speelt niet af", fr="Aucune lecture",
    de="Keine Wiedergabe", el="Καμία αναπαραγωγή", he="לא מנגן", hi="कोई प्लेबैक नहीं",
    hu="Nincs lejátszás", id="Tidak diputar", it="Nessuna riproduzione", ja="再生していません",
    ko="재생 중 아님", ms="Tidak dimainkan", nb="Spiller ikke av", pl="Nie odtwarza",
    ptbr="Não está tocando", ptpt="Não está a reproduzir", ro="Nu se redă", ru="Не воспроизводится",
    sk="Neprehráva sa", es="No se está reproduciendo", sv="Inget spelas upp", th="ไม่ได้เล่นอยู่",
    tr="Çalmıyor", uk="Не відтворюється", vi="Không đang phát", zhhs="未在播放", zhtt="未在播放")

add("This Chapter", ar="هذا الفصل", ca="Aquest capítol", hr="Ovo poglavlje", cs="Tato kapitola",
    da="Dette kapitel", nl="Dit hoofdstuk", fr="Ce chapitre", de="Dieses Kapitel",
    el="Αυτό το κεφάλαιο", he="הפרק הזה", hi="यह अध्याय", hu="Ez a fejezet", id="Bab ini",
    it="Questo capitolo", ja="この章", ko="이 장", ms="Bab ini", nb="Dette kapittelet",
    pl="Ten rozdział", ptbr="Este capítulo", ptpt="Este capítulo", ro="Acest capitol",
    ru="Эта глава", sk="Táto kapitola", es="Este capítulo", sv="Det här kapitlet", th="บทนี้",
    tr="Bu bölüm", uk="Цей розділ", vi="Chương này", zhhs="本章", zhtt="本章")

# 「听完 N 章」：挂章睡的人不肯在章中途停，只在每一章播完时减一格
add("Off After %d Chapters", ar="الإيقاف بعد %d فصول", ca="S'apaga després de %d capítols",
    hr="Gasit nakon %d poglavlja", cs="Vypne po %d kapitolách", da="Sluk efter %d kapitler",
    nl="Uit na %d hoofdstukken", fr="Arrêt après %d chapitres", de="Nach %d Kapiteln beenden",
    el="Σβήνει μετά από %d κεφάλαια", he="ייכבה אחרי %d פרקים", hi="%d अध्याय बाद बंद",
    hu="Kikapcsol %d fejezet után", id="Mati setelah %d bab", it="Si spegne dopo %d capitoli",
    ja="%d 章後にオフ", ko="%d장 후 끄기", ms="Mati selepas %d bab", nb="Av etter %d kapittler",
    pl="Wyłączy po %d rozdziałach", ptbr="Desligar após %d capítulos", ptpt="Desliga após %d capítulos",
    ro="Se oprește după %d capitole", ru="Выключить после %d глав", sk="Vypne po %d kapitolách",
    es="Se apagará tras %d capítulos", sv="Stängs efter %d kapitel", th="ปิดหลังครบ %d บท",
    tr="%d bölüm sonra kapat", uk="Вимкнути після %d глав", vi="Tắt sau %d chương",
    zhhs="听完 %d 章后关闭", zhtt="聽完 %d 章後關閉")

add("Playback Speed", ar="سرعة التشغيل", ca="Velocitat de reproducció", hr="Brzina reprodukcije",
    cs="Rychlost přehrávání", da="Afspilningshastighed", nl="Afspeelsnelheid", fr="Vitesse de lecture",
    de="Wiedergabegeschwindigkeit", el="Ταχύτητα αναπαραγωγής", he="מהירות נגינה", hi="प्लेबैक गति",
    hu="Lejátszási sebesség", id="Kecepatan pemutaran", it="Velocità di riproduzione", ja="再生速度",
    ko="재생 속도", ms="Kelajuan main balik", nb="Avspillingshastighet", pl="Prędkość odtwarzania",
    ptbr="Velocidade de reprodução", ptpt="Velocidade de reprodução", ro="Viteză de redare",
    ru="Скорость воспроизведения", sk="Rýchlosť prehrávania", es="Velocidad de reproducción",
    sv="Uppspelningshastighet", th="ความเร็วในการเล่น", tr="Oynatma hızı", uk="Швидкість відтворення",
    vi="Tốc độ phát", zhhs="语速设置", zhtt="語速設定")

add("Off After This Chapter", ar="الإيقاف بعد هذا الفصل", ca="S'apaga en acabar aquest capítol",
    hr="Gasit nakon ovog poglavlja", cs="Vypne po této kapitole", da="Sluk efter dette kapitel",
    nl="Uit na dit hoofdstuk", fr="Arrêt après ce chapitre", de="Nach diesem Kapitel beenden",
    el="Σβήνει μετά το τέλος του κεφαλαίου", he="ייכבה לאחר הפרק הזה", hi="इस अध्याय के बाद बंद",
    hu="Kikapcsol a fejezet végén", id="Mati setelah bab ini", it="Si spegne alla fine del capitolo",
    ja="この章の後にオフ", ko="이 장 종료 후 끄기", ms="Mati selepas bab ini", nb="Av etter dette kapittelet",
    pl="Wyłączy po tym rozdziale", ptbr="Desligar após este capítulo", ptpt="Desliga após este capítulo",
    ro="Se oprește după acest capitol", ru="Выключить после этой главы", sk="Vypne po tejto kapitole",
    es="Se apagará al terminar este capítulo", sv="Stängs efter detta kapitel", th="ปิดหลังจบบทนี้",
    tr="Bu bölümden sonra kapat", uk="Вимкнути після цього розділу", vi="Tắt sau chương này",
    zhhs="本章结束后关闭", zhtt="本章結束後關閉")

add("No Timer", ar="بدون مؤقت", ca="Sense temporitzador", hr="Bez mjerača vremena", cs="Bez časovače",
    da="Ingen timer", nl="Geen timer", fr="Aucune minuterie", de="Kein Timer", el="Χωρίς χρονοδιακόπτη",
    he="ללא טיימר", hi="कोई टाइमर नहीं", hu="Nincs időzítő", id="Tanpa timer", it="Nessun timer",
    ja="設定なし", ko="타이머 없음", ms="Tiada pemasa", nb="Ikke tidsur", pl="Bez timera",
    ptbr="Sem temporizador", ptpt="Sem temporizador", ro="Fără cronometru", ru="Без таймера",
    sk="Bez časovača", es="Sin temporizador", sv="Ingen timer", th="ไม่ตั้งเวลา", tr="Zamanlayıcı yok",
    uk="Без таймера", vi="Không hẹn giờ", zhhs="不设置", zhtt="不設定")

add("Sleep Timer", ar="مؤقّت النوم", ca="Temporitzador d'adormiment", hr="Mjerač vremena za spavanje",
    cs="Časovač spánku", da="Sleep-timer", nl="Slaaptimer", fr="Minuterie", de="Sleep-Timer",
    el="Χρονοδιακόπτης ύπνου", he="טיימר שינה", hi="स्लीप टाइमर", id="Timer tidur", it="Timer di spegnimento",
    ja="スリープタイマー", ko="취침 타이머", ms="Pemasa tidur", nb="Sleep-timer", pl="Timer snu",
    ptbr="Temporizador de dormir", ptpt="Temporizador de sono",
    ro="Cronometru de somn", ru="Таймер сна", sk="Časovač spánku", es="Temporizador de apagado",
    sv="Insomningstimer", th="ตัวตั้งเวลาปิด", tr="Uyku zamanlayıcısı", uk="Таймер сну",
    vi="Hẹn giờ ngủ", zhhs="定时关闭", zhtt="定時關閉", hu="Elalvási időzítő")

add("Off After %d Minutes", ar="الإيقاف بعد %d دقيقة", ca="S'apaga després de %d minuts",
    hr="Gasit nakon %d minuta", cs="Vypne za %d minut", da="Sluk efter %d minutter",
    nl="Uit na %d minuten", fr="Arrêt après %d minutes", de="Nach %d Minuten beenden",
    el="Σβήνει μετά από %d λεπτά", he="ייכבה אחרי %d דקות", hi="%d मिनट बाद बंद",
    hu="%d perc múlva kikapcsol", id="Mati setelah %d menit", it="Si spegne dopo %d minuti",
    ja="%d 分後にオフ", ko="%d분 후 끄기", ms="Mati selepas %d minit", nb="Av etter %d minutter",
    pl="Wyłączy po %d minutach", ptbr="Desligar após %d minutos", ptpt="Desliga após %d minutos",
    ro="Se oprește după %d minute", ru="Выключится через %d мин", sk="Vypne o %d minút",
    es="Se apagará tras %d minutos", sv="Stängs efter %d minuter", th="ปิดหลัง %d นาที",
    tr="%d dakika sonra kapat", uk="Вимкнеться через %d хв", vi="Tắt sau %d phút",
    zhhs="播放 %d 分钟后关闭", zhtt="播放 %d 分鐘後關閉")

add("Off", ar="إيقاف", ca="Desactivat", hr="Isključeno", cs="Vypnuto", da="Fra", nl="Uit",
    fr="Arrêt", de="Aus", el="Ανενεργό", he="כבה", hi="बंद", hu="Ki", id="Mati", it="Off",
    ja="オフ", ko="끔", ms="Mati", nb="Av", pl="Wył.", ptbr="Desligado", ptpt="Desligado",
    ro="Oprit", ru="Выкл.", sk="Vyp.", es="Desactivado", sv="Av", th="ปิด", tr="Kapalı",
    uk="Вимк.", vi="Tắt", zhhs="关", zhtt="關")

add("%1$d hr %2$d min", ar="%1$d ساعة %2$d دقيقة", ca="%1$d h %2$d min", hr="%1$d h %2$d min",
    cs="%1$d h %2$d min", da="%1$d t %2$d min", nl="%1$d uur %2$d min", fr="%1$d h %2$d min",
    de="%1$d Std %2$d Min", el="%1$d ώ %2$d λ", he="%1$d שע %2$d דק", hi="%1$d घं %2$d मि",
    hu="%1$d ó %2$d p", id="%1$d jam %2$d menit", it="%1$d h %2$d min", ja="%1$d時間%2$d分",
    ko="%1$d시간 %2$d분", ms="%1$d jam %2$d minit", nb="%1$d t %2$d min", pl="%1$d godz %2$d min",
    ptbr="%1$d h %2$d min", ptpt="%1$d h %2$d min", ro="%1$d h %2$d min", ru="%1$d ч %2$d мин",
    sk="%1$d h %2$d min", es="%1$d h %2$d min", sv="%1$d h %2$d min", th="%1$d ชม. %2$d นาที",
    tr="%1$d sa %2$d dk", uk="%1$d год %2$d хв", vi="%1$d giờ %2$d phút",
    zhhs="%1$d 小时 %2$d 分", zhtt="%1$d 小時 %2$d 分")

add("%d hr", ar="%d ساعة", ca="%d h", hr="%d h", cs="%d h", da="%d t", nl="%d uur", fr="%d h",
    de="%d Std", el="%d ώ", he="%d שע", hi="%d घं", hu="%d ó", id="%d jam", it="%d h",
    ja="%d 時間", ko="%d시간", ms="%d jam", nb="%d t", pl="%d godz", ptbr="%d h", ptpt="%d h",
    ro="%d h", ru="%d ч", sk="%d h", es="%d h", sv="%d h", th="%d ชม.", tr="%d sa",
    uk="%d год", vi="%d giờ", zhhs="%d 小时", zhtt="%d 小時")

add("%d min", ar="%d دقيقة", ca="%d min", hr="%d min", cs="%d min", da="%d min", nl="%d min",
    fr="%d min", de="%d Min", el="%d λ", he="%d דק", hi="%d मि", hu="%d p", id="%d menit",
    it="%d min", ja="%d 分", ko="%d분", ms="%d minit", nb="%d min", pl="%d min", ptbr="%d min",
    ptpt="%d min", ro="%d min", ru="%d мин", sk="%d min", es="%d min", sv="%d min",
    th="%d นาที", tr="%d dk", uk="%d хв", vi="%d phút", zhhs="%d 分钟", zhtt="%d 分鐘")

add("Under 1 min", ar="أقل من دقيقة", ca="Menys d'1 minut", hr="Manje od 1 min", cs="Méně než 1 min",
    da="Mindre end 1 min", nl="Minder dan 1 min", fr="Moins d'une minute", de="Unter 1 Minute",
    el="Λιγότερο από 1 λεπτό", he="פחות מדקה", hi="1 मिनट से कम", hu="Kevesebb mint 1 perc",
    id="Kurang dari 1 menit", it="Meno di 1 minuto", ja="1 分未満", ko="1분 미만",
    ms="Kurang 1 minit", nb="Mindre enn 1 min", pl="Mniej niż 1 min", ptbr="Menos de 1 minuto",
    ptpt="Menos de 1 minuto", ro="Mai puțin de 1 minut", ru="Меньше 1 мин", sk="Menej ako 1 min",
    es="Menos de 1 minuto", sv="Mindre än 1 min", th="น้อยกว่า 1 นาที", tr="1 dk'dan az",
    uk="Менше 1 хв", vi="Dưới 1 phút", zhhs="不足 1 分钟", zhtt="不足 1 分鐘")

add('Failed to Delete "%1$@": %2$@',
    ar="تعذر حذف \"%1$@\": %2$@", ca="Error en eliminar \"%1$@\": %2$@",
    hr="Neuspješno brisanje \"%1$@\": %2$@", cs="Nepodařilo se odstranit \"%1$@\": %2$@",
    da="Kunne ikke slette \"%1$@\": %2$@", nl="Verwijderen van \"%1$@\" mislukt: %2$@",
    fr="Échec de la suppression de « %1$@ » : %2$@", de="Löschen von \"%1$@\" fehlgeschlagen: %2$@",
    el="Σφάλμα διαγραφής \"%1$@\": %2$@", he="המחיקה של \"%1$@\" נכשלה: %2$@",
    hi="\"%1$@\" हटाने में विफल: %2$@", hu="\"%1$@\" törlése nem sikerült: %2$@",
    id="Gagal menghapus \"%1$@\": %2$@", it="Eliminazione di \"%1$@\" non riuscita: %2$@",
    ja="「%1$@」の削除に失敗しました：%2$@", ko="%1$@ 삭제 실패: %2$@",
    ms="Gagal memadam \"%1$@\": %2$@", nb="Kunne ikke slette \"%1$@\": %2$@",
    pl="Nie udało się usunąć „%1$@”: %2$@", ptbr="Falha ao apagar \"%1$@\": %2$@",
    ptpt="Falha ao apagar \"%1$@\": %2$@", ro="Ștergerea lui „%1$@” a eșuat: %2$@",
    ru="Не удалось удалить «%1$@»: %2$@", sk="Nepodarilo sa odstrániť \"%1$@\": %2$@",
    es="Error al eliminar \"%1$@\": %2$@", sv="Kunde inte radera \"%1$@\": %2$@",
    th="ลบ \"%1$@\" ไม่สำเร็จ: %2$@", tr="\"%1$@\" silinemedi: %2$@",
    uk="Не вдалося видалити «%1$@»: %2$@", vi="Xóa \"%1$@\" thất bại: %2$@",
    zhhs="删除「%1$@」失败：%2$@", zhtt="刪除「%1$@」失敗：%2$@")

add("System Default", ar="افتراضي النظام", ca="Predeterminat del sistema", hr="Zadano sustavom",
    cs="Výchozí systémové", da="Systemstandard", nl="Systeemstandaard", fr="Valeur par défaut du système",
    de="Systemstandard", el="Προεπιλογή συστήματος", he="ברירת המחדל של המערכת",
    hi="सिस्टम डिफ़ॉल्ट", hu="Rendszerértelmezett", id="Default sistem", it="Predefinita di sistema",
    ja="システム設定に従う", ko="시스템 설정 따르기", ms="Lalai sistem",
    nb="Systemstandard", pl="Domyślne systemowe", ptbr="Padrão do sistema", ptpt="Predefinição do sistema",
    ro="Implicit de sistem", ru="Как в системе", sk="Predvolené systémove", es="Predeterminado del sistema",
    sv="Systemstandard", th="ค่าเริ่มต้นของระบบ", tr="Sistem varsayılanı", uk="Як у системі",
    vi="Mặc định hệ thống", zhhs="跟随系统", zhtt="跟隨系統")

add("Language", ar="اللغة", ca="Idioma", hr="Jezik", cs="Jazyk", da="Sprog", nl="Taal", fr="Langue",
    de="Sprache", el="Γλώσσα", he="שפה", hi="भाषा", hu="Nyelv", id="Bahasa", it="Lingua", ja="言語",
    ko="언어", ms="Bahasa", nb="Språk", pl="Język", ptbr="Idioma", ptpt="Idioma", ro="Limbă",
    ru="Язык", sk="Jazyk", es="Idioma", sv="Språk", th="ภาษา", tr="Dil", uk="Мова", vi="Ngôn ngữ",
    zhhs="语言", zhtt="語言")

add("Restart Required", ar="يلزم إعادة التشغيل", ca="Cal reiniciar", hr="Potrebno je ponovno pokretanje",
    cs="Vyžadován restart", da="Genstart påkrævet", nl="Opnieuw opstarten vereist",
    fr="Redémarrage nécessaire", de="Neustart erforderlich", el="Απαιτείται επανεκκίνηση",
    he="נדרשת הפעלה מחדש", hi="रीस्टार्ट आवश्यक", hu="Újraindítás szükséges", id="Perlu mulai ulang",
    it="È richiesto il riavvio", ja="再起動が必要", ko="재시작 필요", ms="Perlu mula semula",
    nb="Omstart påkrevd", pl="Wymagany restart", ptbr="É necessário reiniciar", ptpt="É necessário reiniciar",
    ro="Necesită repornire", ru="Требуется перезапуск", sk="Vyžaduje sa reštart", es="Requiere reinicio",
    sv="Omstart krävs", th="ต้องเริ่มใหม่", tr="Yeniden başlatma gerekli", uk="Потрібен перезапуск",
    vi="Cần khởi động lại", zhhs="需要重启", zhtt="需要重新啟動")

add("Restart Now", ar="أعد التشغيل الآن", ca="Reinicia ara", hr="Odmah ponovno pokreni",
    cs="Restartovat nyní", da="Genstart nu", nl="Nu opnieuw opstarten", fr="Redémarrer maintenant",
    de="Jetzt neu starten", el="Επανεκκίνηση τώρα", he="הפעל מחדש עכשיו", hi="अभी रीस्टार्ट करें",
    hu="Újraindítás most", id="Mulai ulang sekarang", it="Riavvia ora", ja="今すぐ再起動",
    ko="지금 재시작", ms="Mula semula sekarang", nb="Start på nytt nå", pl="Restartuj teraz",
    ptbr="Reiniciar agora", ptpt="Reiniciar agora", ro="Repornește acum", ru="Перезапустить сейчас",
    sk="Reštartovať teraz", es="Reiniciar ahora", sv="Starta om nu", th="เริ่มใหม่ทันที",
    tr="Şimdi yeniden başlat", uk="Перезапустити зараз", vi="Khởi động lại ngay",
    zhhs="立即重启", zhtt="立即重新啟動")

add("Later", ar="لاحقًا", ca="Més tard", hr="Kasnije", cs="Později", da="Senere", nl="Later",
    fr="Plus tard", de="Später", el="Αργότερα", he="אחר כך", hi="बाद में", hu="Később",
    id="Nanti", it="Più tardi", ja="後で", ko="나중에", ms="Kemudian", nb="Senere", pl="Później",
    ptbr="Depois", ptpt="Mais tarde", ro="Mai târziu", ru="Позже", sk="Neskôr", es="Más tarde",
    sv="Senare", th="ไว้ทีหลัง", tr="Daha sonra", uk="Пізніше", vi="Để sau", zhhs="稍后", zhtt="稍後")

add("Sonux needs to restart to switch language.",
    ar="يجب إعادة تشغيل Sonux لتغيير اللغة.", ca="Cal reiniciar el Sonux per canviar d'idioma.",
    hr="Sonux se mora ponovno pokrenuti za promjenu jezika.", cs="Pro změnu jazyka je třeba Sonux restartovat.",
    da="Sonux skal genstartes for at skifte sprog.", nl="Sonux moet opnieuw worden opgestart om de taal te wijzigen.",
    fr="Sonux doit redémarrer pour changer de langue.", de="Sonux muss neu gestartet werden, um die Sprache zu wechseln.",
    el="Ο Sonux πρέπει να επανεκκινήσει για αλλαγή γλώσσας.", he="יש להפעיל מחדש את Sonux כדי לשנות שפה.",
    hi="भाषा बदलने के लिए Sonux को रीस्टार्ट करना होगा।", hu="A nyelv váltásához indítsa újra a Sonuxot.",
    id="Sonux perlu dimulai ulang untuk mengganti bahasa.", it="Sonux deve essere riavviato per cambiare lingua.",
    ja="言語を切り替えるには Sonux を再起動してください。", ko="언어를 변경하려면 Sonux를 다시 시작하세요.",
    ms="Sonux perlu dimulakan semula untuk menukar bahasa.", nb="Sonux må startes på nytt for å bytte språk.",
    pl="Sonux musi zostać zrestartowany, aby zmienić język.", ptbr="O Sonux precisa ser reiniciado para mudar o idioma.",
    ptpt="O Sonux precisa de reiniciar para mudar o idioma.", ro="Sonux trebuie repornit pentru a schimba limba.",
    ru="Для смены языка Sonux нужно перезапустить.", sk="Na zmenu jazyka je potrebný reštart aplikácie Sonux.",
    es="Sonux debe reiniciarse para cambiar el idioma.", sv="Sonux måste startas om för att byta språk.",
    th="ต้องเริ่ม Sonux ใหม่เพื่อเปลี่ยนภาษา", tr="Dili değiştirmek için Sonux'u yeniden başlatın.",
    uk="Щоб змінити мову, перезапустіть Sonux.", vi="Sonux cần khởi động lại để đổi ngôn ngữ.",
    zhhs="重启 Sonux 后即可切换为新语言。", zhtt="重新啟動 Sonux 後即會切換為新語言。")

add("%d Chapters",
    ar="%d فصل", ca="%d capítols", hr="%d poglavlja", cs="%d kapitol", da="%d kapitler",
    nl="%d hoofdstukken", fr="%d chapitres", de="%d Kapitel", el="%d κεφάλαια", he="%d פרקים",
    hi="%d अध्याय", hu="%d fejezet", id="%d Bab", it="%d capitoli", ja="%d 章", ko="%d화",
    ms="%d Bab", nb="%d kapitler", pl="%d rozdziałów", ptbr="%d capítulos", ptpt="%d capítulos",
    ro="%d capitole", ru="%d глав", sk="%d kapitol", es="%d capítulos", sv="%d kapitel",
    th="%d บท", tr="%d bölüm", uk="%d розділів", vi="%d chương", zhhs="%d 章", zhtt="%d 章")

add("Skip Backward 15 Seconds",
    ar="تخطٍّ للخلف 15 ثانية", ca="Retrocedir 15 segons", hr="Skoči 15 sekundi unatrag",
    cs="Přeskočit o 15 s zpět", da="Spring 15 sekunder tilbage", nl="15 seconden terugspoelen",
    fr="Retour 15 secondes", de="15 Sek. zurück", el="Παράκαμψη 15 δευτ. πίσω",
    he="דילוג לאחור 15 שניות", hi="15 सेकंड पीछे जाएँ", hu="15 másodperc vissza",
    id="Mundur 15 detik", it="Indietro di 15 secondi", ja="15秒戻す", ko="15초 뒤로",
    ms="Langkau 15 detik ke belakang", nb="Løp 15 sekunder bakover", pl="Przewiń o 15 s wstecz",
    ptbr="Retroceder 15 segundos", ptpt="Recuar 15 segundos", ro="Sari înapoi 15 secunde",
    ru="Перемотка на 15 с назад", sk="Preskočiť o 15 s späť", es="Retroceder 15 segundos",
    sv="Spola bakåt 15 sekunder", th="ย้อนหลัง 15 วินาที", tr="15 saniye geri sar",
    uk="Перемотати на 15 с назад", vi="Tua lùi 15 giây", zhhs="快退 15 秒", zhtt="快退 15 秒")

add("Skip Forward 15 Seconds",
    ar="تخطٍّ للأمام 15 ثانية", ca="Avançar 15 segons", hr="Skoči 15 sekundi unaprijed",
    cs="Přeskočit o 15 s dopředu", da="Spring 15 sekunder frem", nl="15 seconden vooruitspoelen",
    fr="Avance 15 secondes", de="15 Sek. vor", el="Παράκαμψη 15 δευτ. μπροστά",
    he="דילוג קדימה 15 שניות", hi="15 सेकंड आगे जाएँ", hu="15 másodperc előre",
    id="Maju 15 detik", it="Avanti di 15 secondi", ja="15秒送り", ko="15초 앞으로",
    ms="Langkau 15 detik ke hadapan", nb="Løp 15 sekunder fremover", pl="Przewiń o 15 s do przodu",
    ptbr="Avançar 15 segundos", ptpt="Avançar 15 segundos", ro="Sari înainte 15 secunde",
    ru="Перемотка на 15 с вперёд", sk="Preskočiť o 15 s dopredu", es="Adelantar 15 segundos",
    sv="Spola framåt 15 sekunder", th="ไปหน้า 15 วินาที", tr="15 saniye ileri sar",
    uk="Перемотати на 15 с уперед", vi="Tua tới 15 giây", zhhs="快进 15 秒", zhtt="快進 15 秒")

add("Play",
    ar="تشغيل", ca="Reprodueix", hr="Reproduciraj", cs="Přehrát", da="Afspil", nl="Afspelen",
    fr="Lire", de="Wiedergeben", el="Αναπαραγωγή", he="נגן", hi="चलाएँ", hu="Lejátszás",
    id="Putar", it="Riproduci", ja="再生", ko="재생", ms="Main", nb="Spill av", pl="Odtwórz",
    ptbr="Reproduzir", ptpt="Reproduzir", ro="Redă", ru="Воспроизвести", sk="Prehrať",
    es="Reproducir", sv="Spela upp", th="เล่น", tr="Oynat", uk="Відтворити", vi="Phát",
    zhhs="播放", zhtt="播放")

add("Pause",
    ar="إيقاف مؤقت", ca="Pausa", hr="Pauza", cs="Pozastavit", da="Pause", nl="Pauzeren",
    fr="Mettre en pause", de="Pause", el="Παύση", he="השהיה", hi="रोकें", hu="Szünet",
    id="Jeda", it="Pausa", ja="一時停止", ko="일시정지", ms="Jeda", nb="Pause", pl="Wstrzymaj",
    ptbr="Pausar", ptpt="Pausar", ro="Pauză", ru="Пауза", sk="Pozastaviť",
    es="Pausar", sv="Pausa", th="หยุดชั่วคราว", tr="Duraklat", uk="Призупинити", vi="Tạm dừng",
    zhhs="暂停", zhtt="暫停")

# ---------------- 文案页（上一笔提交漏补的键） ----------------

add("Chapter Text", ar="نص الفصل", ca="Text del capítol", hr="Tekst poglavlja", cs="Text kapitoly",
    da="Kapiteltekst", nl="Hoofdstuktekst", fr="Texte du chapitre", de="Kapiteltext",
    el="Κείμενο κεφαλαίου", he="טקסט הפרק", hi="अध्याय पाठ", hu="Fejezet szövege",
    id="Teks bab", it="Testo del capitolo", ja="章のテキスト", ko="챕터 텍스트", ms="Teks bab",
    nb="Kapitteltekst", pl="Tekst rozdziału", ptbr="Texto do capítulo", ptpt="Texto do capítulo",
    ro="Textul capitolului", ru="Текст главы", sk="Text kapitoly", es="Texto del capítulo",
    sv="Kapiteltext", th="ข้อความของบท", tr="Bölüm metni", uk="Текст розділу",
    vi="Văn bản chương", zhhs="本章文案", zhtt="本章文案")

# ---------------- 全库字幕搜索 ----------------

add("Search All Text for \"%@\"", ar="ابحث عن «%@» في كل النص", ca="Cerca «%@» en tot el text", hr="Pretraži sav tekst za „%@“",
    cs="Hledat „%@“ v celém textu", da="Søg efter „%@“ i al tekst", nl="„%@“ doorzoeken in alle tekst",
    fr="Rechercher « %@ » dans tout le texte", de="Gesamten Text nach „%@“ durchsuchen",
    el="Αναζήτηση «%@» σε όλο το κείμενο", he="חפש “%@” בכל הטקסט", hi="पूरे पाठ में “%@” खोजें",
    hu="Keresés a teljes szövegben: „%@“", id="Cari “%@” di semua teks",
    it="Cerca “%@” in tutto il testo", ja="「%@」を全文検索", ko="전체 텍스트에서 “%@” 검색",
    ms="Cari “%@” dalam semua teks", nb="Søk etter «%@» i all tekst", pl="Szukaj „%@” w całym tekście",
    ptbr="Pesquisar “%@” em todo o texto", ptpt="Pesquisar “%@” em todo o texto",
    ro="Caută „%@“ în tot textul", ru="Искать «%@» во всём тексте", sk="Hľadať „%@“ v celom texte",
    es="Buscar «%@» en todo el texto", sv="Sök ”%@” i all text", th="ค้นหา “%@” ในข้อความทั้งหมด",
    tr="Tüm metinde “%@” ara", uk="Шукати «%@» в усьому тексті", vi="Tìm “%@” trong toàn bộ văn bản",
    zhhs="全文搜索「%@」", zhtt="全文搜尋「%@」")

add("Searching", ar="جاري البحث", ca="Cercant", hr="Pretraživanje", cs="Probíhá hledání",
    da="Søger", nl="Bezig met zoeken", fr="Recherche en cours", de="Suche läuft",
    el="Αναζήτηση", he="מחפש", hi="खोज जारी है", hu="Keresés", id="Mencari",
    it="Ricerca in corso", ja="検索中", ko="검색 중", ms="Sedang mencari", nb="Søker",
    pl="Wyszukiwanie", ptbr="Pesquisando", ptpt="Pesquisando", ro="Se caută",
    ru="Идёт поиск", sk="Prebieha vyhľadávanie", es="Buscando", sv="Söker",
    th="กำลังค้นหา", tr="Aranıyor", uk="Трива пошук", vi="Đang tìm kiếm", zhhs="正在搜索",
    zhtt="正在搜尋")

add("No Transcripts to Search", ar="لا يوجد نص للبحث فيه", ca="No hi ha text per cercar", hr="Nema teksta za pretraživanje",
    cs="Není žádný text ke hledání", da="Ingen tekst at søge i", nl="Geen tekst om te zoeken",
    fr="Aucun texte à rechercher", de="Kein Text zum Suchen", el="Δεν υπάρχει κείμενο για αναζήτηση",
    he="אין טקסט לחפש בו", hi="खोजने के लिए पाठ नहीं है", hu="Nincs kereshető szöveg",
    id="Tidak ada teks untuk dicari", it="Nessun testo da cercare", ja="検索できる字幕がありません",
    ko="검색할 대본이 없습니다", ms="Tiada teks untuk dicari", nb="Ingen tekst å søke i",
    pl="Brak tekstu do wyszukiwania", ptbr="Não há texto para pesquisar",
    ptpt="Não há texto para pesquisar", ro="Nu există text de căutat",
    ru="Нет текста для поиска", sk="Žiadny text na vyhľadávanie", es="No hay texto que buscar",
    sv="Ingen text att söka i", th="ไม่มีข้อความให้ค้นหา", tr="Aranacak metin yok",
    uk="Немає тексту для пошуку", vi="Không có văn bản để tìm", zhhs="还没有可搜索的字幕",
    zhtt="還沒有可搜尋的字幕")

add("%d Hits", ar="%d تطابق", ca="%d coincidències", hr="%d rezultata", cs="%d výskytů",
    da="%d fund", nl="%d resultaten", fr="%d mentions", de="%d Treffer", el="%d ευρέσεις",
    he="%d התאמות", hi="%d मैच", hu="%d találat", id="%d hasil", it="%d occorrenze",
    ja="%d 箇所", ko="%d개 일치", ms="%d hasil", nb="%d treff", pl="%d trafień", ptbr="%d correspondências",
    ptpt="%d correspondências", ro="%d rezultate", ru="%d совпадений", sk="%d výskytov",
    es="%d coincidencias", sv="%d träffar", th="%d รายการ", tr="%d sonuç",
    uk="%d збігів", vi="%d kết quả", zhhs="命中 %d 句", zhtt="命中 %d 句")

add("%d More Hits Not Listed", ar="%d تطابق آخر غير مُدرج", ca="%d coincidències més no enumerades",
    hr="%d dodatnih rezultata nije navedeno", cs="%d dalších výskytů není uvedeno",
    da="%d yderligere fund vises ikke", nl="%d resultaten niet weergegeven",
    fr="%d autres mentions non affichées", de="%d weitere Treffer nicht aufgeführt",
    el="%d ακόμη ευρέσεις δεν παραθέτονται", he="%d התאמות נוספות אינן ברשימה",
    hi="%d और मैच सूचीबद्ध नहीं हैं", hu="%d további találat nincs feltüntetve",
    id="%d hasil lainnya tidak ditampilkan", it="%d occorrenze aggiuntive non elencate",
    ja="他 %d 箇所は非表示", ko="나머지 %d개는 표시되지 않음", ms="%d hasil lagi tidak disenaraikan",
    nb="%d treff vises ikke", pl="%d dalszych trafień nie zostało wymienionych",
    ptbr="Mais %d correspondências não listadas", ptpt="Mais %d correspondências não listadas",
    ro="%d rezultate în plus nu sunt listate", ru="Ещё %d совпадений не показано",
    sk="%d ďalších výskytov nie je uvedených", es="%d coincidencias más no listadas",
    sv="Ytterligare %d träffar visas inte", th="อีก %d รายการไม่แสดง",
    tr="%d sonuç daha listelenmedi", uk="Ще %d збігів не показано", vi="%d kết quả khác không được liệt kê",
    zhhs="另有 %d 句未列出", zhtt="另有 %d 句未列出")

add("Play \"%1$@\" at %2$@", ar="شغّل «%1$@» عند %2$@", ca="Reprodueix «%1$@» a %2$@", hr="Reproduziraj „%1$@“ na %2$@",
    cs="Přehrát „%1$@“ v %2$@", da="Afspil „%1$@“ ved %2$@", nl="“%1$@” afspelen op %2$@",
    fr="Lire « %1$@ » à %2$@", de="„%1$@“ bei %2$@ wiedergeben", el="Αναπαραγωγή «%1$@» στο %2$@",
    he="הפעל “%1$@” ב-%2$@", hi="%2$@ पर “%1$@” चलाएँ", hu="„%1$@” lejátszása itt: %2$@",
    id="Putar “%1$@” pada %2$@", it="Riproduci “%1$@” alle %2$@", ja="%2$@ で「%1$@」を再生",
    ko="%2$@에서 “%1$@” 재생", ms="Main “%1$@” pada %2$@", nb="Spill av «%1$@» ved %2$@",
    pl="Odtwórz „%1$@” o %2$@", ptbr="Reproduzir “%1$@” em %2$@", ptpt="Reproduzir “%1$@” em %2$@",
    ro="Redă „%1$@” la %2$@", ru="Воспроизвести «%1$@» на %2$@", sk="Prehrať „%1$@“ o %2$@",
    es="Reproducir «%1$@» en %2$@", sv="Spara ”%1$@” vid %2$@", th="เล่น “%1$@” ที่ %2$@",
    tr="“%1$@” %2$@ için oynat", uk="Відтворити «%1$@» на %2$@", vi="Phát “%1$@” tại %2$@",
    zhhs="从 %2$@ 播放「%1$@」", zhtt="從 %2$@ 播放「%1$@」")


add("Quote Card", ar="بطاقة الاقتباس", ca="Targeta de citació", hr="Kartica citata",
    cs="Karta citátu", da="Citatkort", nl="Citaatkaart", fr="Carte de citation",
    de="Zitatskarte", el="Κάρτα παράθεσης", he="כרטיס ציטוט", hi="उद्धरण कार्ड",
    hu="Idézetkártya", id="Kartu kutipan", it="Carta della citazione", ja="引用カード",
    ko="인용 카드", ms="Kad petikan", nb="Sitatkort", pl="Karta cytatu",
    ptbr="Cartão de citação", ptpt="Cartão de citação", ro="Card de citat",
    ru="Карточка цитаты", sk="Karta citátu", es="Tarjeta de cita", sv="Citatkort",
    th="การ์ดคำอ้าง", tr="Alıntı kartı", uk="Картка цитати", vi="Thẻ trích dẫn",
    zhhs="摘录卡片", zhtt="摘錄卡片")

add("Share", ar="مشاركة", ca="Comparteix", hr="Dijeli", cs="Sdílet", da="Del",
    nl="Delen", fr="Partager", de="Teilen", el="Κοινοποίηση", he="שיתוף",
    hi="साझा करें", hu="Megosztás", id="Bagikan", it="Condividi", ja="共有",
    ko="공유", ms="Kongsi", nb="Del", pl="Udostępnij", ptbr="Compartilhar",
    ptpt="Partilhar", ro="Partajează", ru="Поделиться", sk="Zdieľať", es="Compartir",
    sv="Dela", th="แชร์", tr="Paylaş", uk="Поділитися", vi="Chia sẻ",
    zhhs="分享", zhtt="分享")


add("Sort By", ar="ترتيب حسب", ca="Ordena per", hr="Poredaj po", cs="Řadit podle",
    da="Sortér efter", nl="Sorteren op", fr="Trier par", de="Sortieren nach",
    el="Ταξινόμηση κατά", he="מיין לפי", hi="क्रमबद्ध करें", hu="Rendezés",
    id="Urutkan berdasarkan", it="Ordina per", ja="並べ替え", ko="정렬 기준",
    ms="Isih ikut", nb="Sorter etter", pl="Sortuj według", ptbr="Ordenar por",
    ptpt="Ordenar por", ro="Sortați după", ru="Сортировка", sk="Zoradiť podľa",
    es="Ordenar por", sv="Sortera efter", th="เรียงตาม", tr="Sıralama Ölçütü",
    uk="Сортувати за", vi="Sắp xếp theo", zhhs="排序方式", zhtt="排序方式")

add("File Name", ar="اسم الملف", ca="Nom del fitxer", hr="Naziv datoteke",
    cs="Název souboru", da="Filnavn", nl="Bestandsnaam", fr="Nom du fichier",
    de="Dateiname", el="Όνομα αρχείου", he="שם הקובץ", hi="फ़ाइल नाम",
    hu="Fájlnév", id="Nama file", it="Nome file", ja="ファイル名", ko="파일 이름",
    ms="Nama fail", nb="Filnavn", pl="Nazwa pliku", ptbr="Nome do arquivo",
    ptpt="Nome do ficheiro", ro="Nume fișier", ru="Имя файла", sk="Názov súboru",
    es="Nombre del archivo", sv="Filnamn", th="ชื่อไฟล์", tr="Dosya adı",
    uk="Назва файлу", vi="Tên tệp", zhhs="文件名称", zhtt="檔案名稱")

add("Recently Added", ar="أُضيفت مؤخرًا", ca="Afegits recentment", hr="Nedavno dodano",
    cs="Nedávno přidané", da="Tilføjet for nylig", nl="Onlangs toegevoegd",
    fr="Ajoutés récemment", de="Zuletzt hinzugefügt", el="Πρόσφατα προστεθέντα",
    he="נוסף לאחרונה", hi="हाल ही में जोड़ा गया", hu="Legutóbb hozzáadva",
    id="Baru ditambahkan", it="Aggiunti di recente", ja="最近追加", ko="최근 추가",
    ms="Baru ditambah", nb="Nylig lagt til", pl="Ostatnio dodane",
    ptbr="Adicionados recentemente", ptpt="Adicionados recentemente",
    ro="Adăugate recent", ru="Недавно добавленные", sk="Nedávno pridané",
    es="Añadidos recientemente", sv="Nyligen tillagda", th="เพิ่มล่าสุด",
    tr="Yeni eklenen", uk="Нещодавно додані", vi="Gần đây đã thêm",
    zhhs="最近添加", zhtt="最近新增")

add("Recently Played", ar="تمت التشغيل مؤخرًا", ca="Reproduïts recentment",
    hr="Nedavno reproducirano", cs="Nedávno přehrávané", da="Senest afspillet",
    nl="Onlangs afgespeeld", fr="Écoutés récemment", de="Zuletzt gehört",
    el="Πρόσφατα αναπαραχθέντα", he="הושמע לאחרונה", hi="हाल ही में सुना",
    hu="Legutóbb lejátszva", id="Baru diputar", it="Riprodotti di recente",
    ja="最近再生", ko="최근 재생", ms="Baru dimainkan", nb="Nylig spilt av",
    pl="Ostatnio odtwarzane", ptbr="Tocados recentemente", ptpt="Reproduzidos recentemente",
    ro="Redate recent", ru="Недавно прослушанные", sk="Nedávno prehrávané",
    es="Reproducidos recientemente", sv="Nyligen spelade", th="เล่นล่าสุด",
    tr="Son çalınan", uk="Нещодавно прослухані", vi="Gần đây đã phát",
    zhhs="最近收听", zhtt="最近收聽")

add("Playback", ar="التشغيل", ca="Reproducció", hr="Reprodukcija", cs="Přehrávání", da="Afspilning",
    nl="Afspelen", fr="Lecture", de="Wiedergabe", el="Αναπαραγωγή", he="השמעה", hi="प्लेबैक",
    hu="Lejátszás", id="Pemutaran", it="Riproduzione", ja="再生", ko="재생", ms="Main semula",
    nb="Avspilling", pl="Odtwarzanie", ptbr="Reprodução", ptpt="Reprodução", ro="Redare",
    ru="Воспроизведение", sk="Prehrávanie", es="Reproducción", sv="Uppspelning", th="การเล่น",
    tr="Oynatma", uk="Відтворення", vi="Phát lại", zhhs="播放", zhtt="播放")

add("Trim Silence", ar="تخطّ الصمت", ca="Omet el silenci", hr="Preskoči tišinu", cs="Přeskočit ticho",
    da="Spring stilhed over", nl="Stilte overslaan", fr="Sauter les silences", de="Stille überspringen",
    el="Παράλειψη σιωπής", he="דילוג על שתיקות", hi="मौनता छोड़ें", hu="Csend átugrása",
    id="Lewati keheningan", it="Salta i silenzi", ja="無音をスキップ", ko="무음 건너뛰기",
    ms="Langkau senyap", nb="Hopp over stillhet", pl="Pomiń ciszę", ptbr="Pular silêncios",
    ptpt="Saltar silêncios", ro="Omite liniștea", ru="Пропуск тишины", sk="Preskočiť ticho",
    es="Omitir silencios", sv="Hoppa över tystnad", th="ข้ามความเงียบ", tr="Sessizliği atla",
    uk="Пропуск тиші", vi="Bỏ qua đoạn im", zhhs="跳过静音", zhtt="跳過靜音")

add("Voice Boost", ar="تعزيز الصوت", ca="Realç de veu", hr="Pojačanje glasa", cs="Zvýraznění hlasu",
    da="Stemmeforstærker", nl="Stemversterking", fr="Amplification de la voix", de="Sprachverstärkung",
    el="Ενίσχυση φωνής", he="הגברת דיבור", hi="आवाज़ बूस्ट", hu="Hangkiemelés", id="Penguat suara",
    it="Potenziamento voce", ja="音声ブースト", ko="음성 부스트", ms="Perkasa suara",
    nb="Forsterk tale", pl="Wzmocnienie głosu", ptbr="Realce de voz", ptpt="Realce de voz",
    ro="Amplificare voce", ru="Усиление речи", sk="Zvýraznenie reči", es="Realce de voz",
    sv="Röstförstärkning", th="เสริมเสียงพูด", tr="Ses güçlendirme", uk="Підсилення мовлення",
    vi="Tăng cường giọng nói", zhhs="语音增强", zhtt="語音增強")

# 跳过静音的三档：分段控件里的短词，宁可对仗也不要长
add("Light", ar="خفيف", ca="Lleuger", hr="Blago", cs="Mírně", da="Let", nl="Licht", fr="Léger",
    de="Leicht", el="Ελαφρύ", he="קל", hi="हल्का", hu="Enyhe", id="Ringan", it="Leggero",
    ja="軽め", ko="가볍게", ms="Ringan", nb="Lett", pl="Łagodnie", ptbr="Suave", ptpt="Suave",
    ro="Ușor", ru="Лёгкий", sk="Mierne", es="Ligero", sv="Lätt", th="เบา", tr="Hafif",
    uk="Легкий", vi="Nhẹ", zhhs="轻度", zhtt="輕度")

add("Standard", ar="قياسي", ca="Estàndard", hr="Standardno", cs="Standardní", da="Standard",
    nl="Standaard", fr="Standard", de="Standard", el="Πρότυπο", he="סטנדרטי", hi="मानक",
    hu="Szabványos", id="Standar", it="Standard", ja="標準", ko="표준", ms="Standard",
    nb="Standard", pl="Standardowo", ptbr="Padrão", ptpt="Padrão", ro="Standard", ru="Обычный",
    sk="Štandard", es="Estándar", sv="Standard", th="มาตรฐาน", tr="Standart", uk="Стандартний",
    vi="Tiêu chuẩn", zhhs="标准", zhtt="標準")

add("Heavy", ar="قوي", ca="Fort", hr="Jako", cs="Silně", da="Kraftig", nl="Sterk", fr="Fort",
    de="Stark", el="Ισχυρό", he="חזק", hi="तेज़", hu="Erős", id="Berat", it="Forte", ja="強め",
    ko="강하게", ms="Berat", nb="Kraftig", pl="Mocno", ptbr="Forte", ptpt="Forte", ro="Puternic",
    ru="Сильный", sk="Silno", es="Fuerte", sv="Kraftig", th="หนัก", tr="Güçlü", uk="Сильний",
    vi="Mạnh", zhhs="重度", zhtt="重度")


# 下面六条是从 Support/Localizable.xcstrings 里回捞回来的：上次做收听报告页时
# 只把键写进了 catalog，没进这张表，脚本一跑就会把它们删掉。补齐后表与 catalog 一致。
add("%d Books", ar="%d كتب", ca="%d llibres", hr="%d knjiga", cs="%d knih", da="%d bøger", nl="%d boeken",
    fr="%d livres", de="%d Bücher", el="%d βιβλία", he="%d ספרים", hi="%d किताबें", hu="%d könyv", id="%d buku",
    it="%d libri", ja="%d 冊", ko="%d권", ms="%d buku", nb="%d bøker", pl="%d książek", ptbr="%d livros",
    ptpt="%d livros", ro="%d cărți", ru="%d книг", sk="%d kníh", es="%d libros", sv="%d böcker", th="%d เล่ม",
    tr="%d kitap", uk="%d книг", vi="%d cuốn", zhhs="%d 本", zhtt="%d 本")
add("%d Listening Report", ar="تقرير الاستماع %d", ca="Informe d'escolta %d", hr="Izvještaj slušanja %d",
    cs="Přehled poslechu %d", da="Lytterapport %d", nl="Luisteroverzicht %d", fr="Rapport d'écoute %d",
    de="Hörbericht %d", el="Έκθεση ακρόασης %d", he="דוח האזנה %d", hi="सुनने की रिपोर्ट %d",
    hu="Hallgatási riport %d", id="Laporan mendengarkan %d", it="Report di ascolto %d", ja="%d 年の再生レポート",
    ko="%d년 듣기 리포트", ms="Laporan mendengar %d", nb="Lytterapport %d", pl="Raport słuchania %d",
    ptbr="Relatório de escuta %d", ptpt="Relatório de escuta %d", ro="Raport de ascultare %d",
    ru="Отчёт прослушивания %d", sk="Prehľad posluchu %d", es="Informe de escucha %d", sv="Lyssningsrapport %d",
    th="รายงานการฟัง %d", tr="Dinleme raporu %d", uk="Звіт прослуховування %d", vi="Báo cáo nghe %d",
    zhhs="%d 年收听报告", zhtt="%d 年收聽報告")
add("Books Finished", ar="كتب مُنهية", ca="Llibres acabats", hr="Dovršene knjige", cs="Dokončené knihy",
    da="Færdige bøger", nl="Voltooide boeken", fr="Livres écoutés", de="Abgeschlossene Bücher",
    el="Ολοκληρωμένα βιβλία", he="ספרים שהושלמו", hi="पूरी किताबें", hu="Befejezett könyvek", id="Buku tuntas",
    it="Libri terminati", ja="聴き終わった本", ko="듣기 마친 책", ms="Buku tamat", nb="Ferdige bøker", pl="Ukończone książki",
    ptbr="Livros concluídos", ptpt="Livros concluídos", ro="Cărți terminate", ru="Дослушанные книги",
    sk="Dokončené knihy", es="Libros terminados", sv="Avklarade böcker", th="หนังสือที่ฟังจบ",
    tr="Tamamlanan kitaplar", uk="Дослухані книги", vi="Sách đã nghe xong", zhhs="听完", zhtt="聽完")
add("Days Listened", ar="أيام الاستماع", ca="Dies d'escolta", hr="Dana slušanja", cs="Dny poslechu", da="Lyttedage",
    nl="Luisterdagen", fr="Jours d'écoute", de="Hörtage", el="Ημέρες ακρόασης", he="ימי האזנה", hi="सुनने के दिन",
    hu="Hallgatási napok", id="Hari mendengarkan", it="Giorni di ascolto", ja="再生日数", ko="듣기 일수",
    ms="Hari mendengar", nb="Lyttedager", pl="Dni słuchania", ptbr="Dias de escuta", ptpt="Dias de escuta",
    ro="Zile de ascultare", ru="Дни прослушивания", sk="Dny posluchu", es="Días de escucha", sv="Lyssningsdagar",
    th="วันที่ฟัง", tr="Dinleme günü", uk="Дні прослуховування", vi="Ngày nghe", zhhs="收听天数", zhtt="收聽天數")
add("Listening Time", ar="وقت الاستماع", ca="Temps d'escolta", hr="Vrijeme slušanja", cs="Čas poslechu",
    da="Lyttetid", nl="Luistertijd", fr="Temps d'écoute", de="Hörzeit", el="Χρόνος ακρόασης", he="זמן האזנה",
    hi="सुनने का समय", hu="Hallgatási idő", id="Waktu mendengarkan", it="Tempo di ascolto", ja="再生時間", ko="듣기 시간",
    ms="Masa mendengar", nb="Lyttetid", pl="Czas słuchania", ptbr="Tempo de escuta", ptpt="Tempo de escuta",
    ro="Timp de ascultare", ru="Время прослушивания", sk="Čas posluchu", es="Tiempo de escucha", sv="Lyssningstid",
    th="เวลาฟัง", tr="Dinleme süresi", uk="Час прослуховування", vi="Thời gian nghe", zhhs="收听时长", zhtt="收聽時長")
add("This Month", ar="هذا الشهر", ca="Aquest mes", hr="Ovaj mjesec", cs="Tento měsíc", da="Denne måned",
    nl="Deze maand", fr="Ce mois-ci", de="Dieser Monat", el="Αυτός ο μήνας", he="החודש הזה", hi="इस महीने",
    hu="Ez a hónap", id="Bulan ini", it="Questo mese", ja="今月", ko="이번 달", ms="Bulan ini", nb="Denne måneden",
    pl="Ten miesiąc", ptbr="Este mês", ptpt="Este mês", ro="Luna aceasta", ru="Этот месяц", sk="Tento mesiac",
    es="Este mes", sv="Denna månad", th="เดือนนี้", tr="Bu ay", uk="Цей місяць", vi="Tháng này", zhhs="本月",
    zhtt="本月")


add("Your library is empty.", ar="مكتبتك فارغة.", ca="La vostra biblioteca és buida.",
    hr="Tvoja biblioteka je prazna.", cs="Vaše knihovna je prázdná.", da="Dit bibliotek er tomt.",
    nl="Je bibliotheek is leeg.", fr="Votre bibliothèque est vide.", de="Deine Bibliothek ist leer.",
    el="Η βιβλιοθήκη σας είναι άδεια.", he="הספרייה שלך ריקה.", hi="आपकी लाइब्रेरी खाली है।",
    hu="A könyvtárad üres.", id="Pustaka Anda kosong.", it="La tua libreria è vuota.",
    ja="ライブラリは空です。", ko="라이브러리가 비어 있습니다.", ms="Pustaka anda kosong.",
    nb="Biblioteket ditt er tomt.", pl="Twoja biblioteka jest pusta.", ptbr="Sua biblioteca está vazia.",
    ptpt="A tua biblioteca está vazia.", ro="Biblioteca ta este goală.", ru="Ваша библиотека пуста.",
    sk="Vaša knižnica je prázdna.", es="Tu biblioteca está vacía.", sv="Ditt bibliotek är tomt.",
    th="คลังของคุณว่างเปล่า", tr="Kitaplığın boş.", uk="Ваша бібліотека порожня.",
    vi="Thư viện của bạn đang trống.", zhhs="你的书库是空的。", zhtt="你的書庫是空的。")

add("I couldn’t find that book in Sonux.", ar="تعذّر العثور على هذا الكتاب في Sonux.",
    ca="No s’ha trobat aquest llibre a Sonux.", hr="Knjiga nije pronađena u Sonuxu.",
    cs="Tato kniha nebyla v Sonuxu nalezena.", da="Bogen blev ikke fundet i Sonux.",
    nl="Dat boek is niet gevonden in Sonux.", fr="Ce livre est introuvable dans Sonux.",
    de="Dieses Buch wurde in Sonux nicht gefunden.", el="Το βιβλίο δεν βρέθηκε στο Sonux.",
    he="ספר זה לא נמצא ב־Sonux.", hi="यह किताब Sonux में नहीं मिली।",
    hu="A könyv nem található a Sonux alkalmazásban.", id="Buku itu tidak ditemukan di Sonux.",
    it="Il libro non è stato trovato in Sonux.", ja="その本は Sonux に見つかりませんでした。",
    ko="해당 책을 Sonux에서 찾을 수 없습니다.", ms="Buku itu tidak ditemui dalam Sonux.",
    nb="Boken ble ikke funnet i Sonux.", pl="Nie znaleziono tej książki w Sonux.",
    ptbr="Esse livro não foi encontrado no Sonux.", ptpt="Este livro não foi encontrado no Sonux.",
    ro="Cartea nu a fost găsită în Sonux.", ru="Эта книга не найдена в Sonux.",
    sk="Táto kniha sa v Sonux nenašla.", es="No se encontró ese libro en Sonux.",
    sv="Boken hittades inte i Sonux.", th="ไม่พบหนังสือ đóใน Sonux", tr="Bu kitap Sonux’ta bulunamadı.",
    uk="Цю книгу не знайдено в Sonux.", vi="Không tìm thấy cuốn sách đó trong Sonux.",
    zhhs="在 Sonux 里找不到那本书。", zhtt="在 Sonux 裡找不到那本書。")

add("Nothing is playing in Sonux yet.", ar="لا يوجد شيء قيد التشغيل في Sonux بعد.",
    ca="Encara no sona res a Sonux.", hr="Ništa se ne reproducira u Sonuxu.",
    cs="V Sonuxu se právě nic nepřehrává.", da="Der afspilles ikke noget i Sonux.",
    nl="Er speelt momenteel niets in Sonux.", fr="Rien n’est en cours de lecture dans Sonux.",
    de="In Sonux läuft gerade keine Wiedergabe.", el="Δεν παίζει κάτι στο Sonux προς το παρόν.",
    he="שום דבר לא מנגן כרגע ב־Sonux.", hi="Sonux में अभी कुछ नहीं चल रहा।",
    hu="Jelenleg semmi sem szól a Sonuxban.", id="Tidak ada yang diputar di Sonux.",
    it="Non c’è nulla in riproduzione in Sonux.", ja="Sonux で再生中のものはありません。",
    ko="Sonux에서 재생 중인 항목이 없습니다.", ms="Tiada apa-apa dimainkan dalam Sonux.",
    nb="Ingenting spilles av i Sonux nå.", pl="Nic nie jest odtwarzane w Sonux.",
    ptbr="Nada está sendo reproduzido no Sonux.", ptpt="Nada está a ser reproduzido no Sonux.",
    ro="Nimic nu rulează în Sonux.", ru="В Sonux сейчас ничего не играет.",
    sk="V Sonux sa práve nič neprehráva.", es="No hay nada sonando en Sonux.",
    sv="Inget spelas upp i Sonux just nu.", th="ยังไม่มีอะไรเล่นใน Sonux",
    tr="Sonux’ta şu anda çalan bir şey yok.", uk="У Sonux зараз нічого не відтворюється.",
    vi="Không có gì đang phát trong Sonux.", zhhs="Sonux 里还没有正在播放的内容。",
    zhtt="Sonux 裡還沒有正在播放的內容。")


# ---------------- App Intents（Siri 与快捷指令）的文案 ----------------
#
# 这些句子不走 L()：App Intents 的标题、参数名、说法都要求编译期就能定位，
# 系统在构建时把它们抽进 Sonux.app/Metadata.appintents 与 nlu.appintents 里，
# 运行时再按这里的键取词。所以键必须和 Intents/*.swift 里的字面量一字不差 ——
# 主函数会逐个回查代码，改了字面量忘了同步这张表，构建脚本报错退出。
INTENT_KEYS = [
    "Play a Book",
    "Play a book from your Sonux library.",
    "Next Chapter",
    "Previous Chapter",
    "Book",
    "Play ${book}",
]

# Siri 那几句说法在另一张表里（编译成 AppShortcuts.strings，不在 Localizable 里），
# 键里的 ${applicationName} 就是代码里写的 \(.applicationName)
SHORTCUT_KEYS = [
    "Play my book in ${applicationName}",
    "Continue listening in ${applicationName}",
    "Next chapter in ${applicationName}",
    "Previous chapter in ${applicationName}",
]

add("Play a Book", ar="تشغيل كتاب", ca="Reprodueix un llibre", hr="Reproduciraj knjigu",
    cs="Přehrát knihu", da="Afspil en bog", nl="Boek afspelen", fr="Lire un livre",
    de="Buch wiedergeben", el="Αναπαραγωγή βιβλίου", he="נגן ספר", hi="किताब चलाएँ",
    hu="Könyv lejátszása", id="Putar buku", it="Riproduci un libro", ja="本を再生",
    ko="책 재생", ms="Main buku", nb="Spill av en bok", pl="Odtwórz książkę",
    ptbr="Reproduzir um livro", ptpt="Reproduzir um livro", ro="Redă o carte",
    ru="Воспроизвести книгу", sk="Prehrať knihu", es="Reproducir un libro",
    sv="Spela upp en bok", th="เล่นหนังสือ", tr="Kitap oynat", uk="Відтворити книгу",
    vi="Phát một cuốn sách", zhhs="播放一本书", zhtt="播放一本書")

add("Play a book from your Sonux library.", ar="شغّل كتابًا من مكتبتك في Sonux.",
    ca="Reprodueix un llibre de la vostra biblioteca de Sonux.",
    hr="Reproduciraj knjigu iz svoje Sonux biblioteke.",
    cs="Přehraj knihu ze své knihovny Sonux.", da="Afspil en bog fra dit Sonux-bibliotek.",
    nl="Speel een boek af uit je Sonux-bibliotheek.", fr="Lisez un livre de votre bibliothèque Sonux.",
    de="Spiele ein Buch aus deiner Sonux-Bibliothek wieder.",
    el="Αναπαραγωγή βιβλίου από τη βιβλιοθήκη σας στο Sonux.", he="נגן ספר מהספרייה שלך ב־Sonux.",
    hi="Sonux लाइब्रेरी से किताब चलाएँ।", hu="Könyv lejátszása a Sonux-könyvtáradban.",
    id="Putar buku dari pustaka Sonux Anda.", it="Riproduci un libro dalla tua libreria Sonux.",
    ja="Sonux ライブラリの本を再生します。", ko="Sonux 라이브러리의 책을 재생합니다.",
    ms="Main buku daripada pustaka Sonux anda.", nb="Spill av en bok fra Sonux-biblioteket ditt.",
    pl="Odtwórz książkę z Twojej biblioteki Sonux.", ptbr="Reproduz um livro da sua biblioteca no Sonux.",
    ptpt="Reproduz um livro da tua biblioteca no Sonux.", ro="Redă o carte din biblioteca ta Sonux.",
    ru="Воспроизвести книгу из библиотеки Sonux.", sk="Prehrať knihu z tvojej knižnice Sonux.",
    es="Reproduce un libro de tu biblioteca de Sonux.", sv="Spela upp en bok från ditt Sonux-bibliotek.",
    th="เล่นหนังสือจากคลัง Sonux ของคุณ", tr="Sonux kitaplığından bir kitap oynatın.",
    uk="Відтворити книгу з вашої бібліотеки Sonux.", vi="Phát một cuốn sách từ thư viện Sonux của bạn.",
    zhhs="播放你 Sonux 书库里的一本书。", zhtt="播放你 Sonux 書庫裡的一本書。")

add("Next Chapter", ar="الفصل التالي", ca="Capítol següent", hr="Sljedeće poglavlje",
    cs="Další kapitola", da="Næste kapitel", nl="Volgend hoofdstuk", fr="Chapitre suivant",
    de="Nächstes Kapitel", el="Επόμενο κεφάλαιο", he="הפרק הבא", hi="अगला अध्याय",
    hu="Következő fejezet", id="Bab berikutnya", it="Capitolo successivo", ja="次の章",
    ko="다음 장", ms="Bab seterusnya", nb="Neste kapittel", pl="Następny rozdział",
    ptbr="Próximo capítulo", ptpt="Capítulo seguinte", ro="Capitolul următor",
    ru="Следующая глава", sk="Ďalšia kapitola", es="Siguiente capítulo", sv="Nästa kapitel",
    th="บทถัดไป", tr="Sonraki bölüm", uk="Наступний розділ", vi="Chương tiếp theo",
    zhhs="下一章", zhtt="下一章")

add("Previous Chapter", ar="الفصل السابق", ca="Capítol anterior", hr="Prethodno poglavlje",
    cs="Předchozí kapitola", da="Forrige kapitel", nl="Vorige hoofdstuk", fr="Chapitre précédent",
    de="Vorheriges Kapitel", el="Προηγούμενο κεφάλαιο", he="הפרק הקודם", hi="पिछला अध्याय",
    hu="Előző fejezet", id="Bab sebelumnya", it="Capitolo precedente", ja="前の章",
    ko="이전 장", ms="Bab sebelumnya", nb="Forrige kapittel", pl="Poprzedni rozdział",
    ptbr="Capítulo anterior", ptpt="Capítulo anterior", ro="Capitolul anterior",
    ru="Предыдущая глава", sk="Predchádzajúca kapitola", es="Capítulo anterior",
    sv="Föregående kapitel", th="บทก่อนหน้า", tr="Önceki bölüm", uk="Попередній розділ",
    vi="Chương trước", zhhs="上一章", zhtt="上一章")

add("Book", ar="كتاب", ca="Llibre", hr="Knjiga", cs="Kniha", da="Bog", nl="Boek", fr="Livre",
    de="Buch", el="Βιβλίο", he="ספר", hi="किताब", hu="Könyv", id="Buku", it="Libro", ja="本",
    ko="책", ms="Buku", nb="Bok", pl="Książka", ptbr="Livro", ptpt="Livro", ro="Carte",
    ru="Книга", sk="Kniha", es="Libro", sv="Bok", th="หนังสือ", tr="Kitap", uk="Книга",
    vi="Cuốn sách", zhhs="书", zhtt="書")

add("Play ${book}", ar="شغّل ${book}", ca="Reprodueix ${book}", hr="Reproduciraj ${book}",
    cs="Přehrát ${book}", da="Afspil ${book}", nl="${book} afspelen", fr="Lire ${book}",
    de="${book} wiedergeben", el="Αναπαραγωγή ${book}", he="נגן את ${book}", hi="${book} चलाएँ",
    hu="${book} lejátszása", id="Putar ${book}", it="Riproduci ${book}", ja="${book}を再生",
    ko="${book} 재생", ms="Main ${book}", nb="Spill av ${book}", pl="Odtwórz ${book}",
    ptbr="Reproduzir ${book}", ptpt="Reproduzir ${book}", ro="Redă ${book}",
    ru="Воспроизвести ${book}", sk="Prehrať ${book}", es="Reproducir ${book}",
    sv="Spela upp ${book}", th="เล่น ${book}", tr="${book} oynat", uk="Відтворити ${book}",
    vi="Phát ${book}", zhhs="播放${book}", zhtt="播放${book}")

add("Play my book in ${applicationName}", ar="شغّل كتابي في ${applicationName}",
    ca="Reprodueix el meu llibre a ${applicationName}", hr="Reproduciraj moju knjigu u ${applicationName}",
    cs="Přehrát mou knihu v ${applicationName}", da="Afspil min bog i ${applicationName}",
    nl="Mijn boek afspelen in ${applicationName}", fr="Lis mon livre dans ${applicationName}",
    de="Mein Buch in ${applicationName} wiedergeben", el="Αναπαραγωγή του βιβλίου μου στο ${applicationName}",
    he="נגן את הספר שלי ב־${applicationName}", hi="${applicationName} में मेरी किताब चलाएँ",
    hu="A könyvem lejátszása a ${applicationName} alkalmazásban", id="Putar buku saya di ${applicationName}",
    it="Riproduci il mio libro in ${applicationName}", ja="${applicationName}で本を再生",
    ko="${applicationName}에서 내 책 재생", ms="Main buku saya dalam ${applicationName}",
    nb="Spill av boken min i ${applicationName}", pl="Odtwórz moją książkę w ${applicationName}",
    ptbr="Reproduzir meu livro no ${applicationName}", ptpt="Reproduzir o meu livro no ${applicationName}",
    ro="Redă cartea mea în ${applicationName}", ru="Воспроизвести мою книгу в ${applicationName}",
    sk="Prehrať moju knihu v ${applicationName}", es="Reproducir mi libro en ${applicationName}",
    sv="Spela min bok i ${applicationName}", th="เล่นหนังสือของฉันใน ${applicationName}",
    tr="${applicationName} içinde kitabımı oynat", uk="Відтворити мою книгу в ${applicationName}",
    vi="Phát cuốn sách của tôi trong ${applicationName}", zhhs="在${applicationName}里播放我的书",
    zhtt="在${applicationName}裡播放我的書")

add("Continue listening in ${applicationName}", ar="أكمل الاستماع في ${applicationName}",
    ca="Continua escoltant a ${applicationName}", hr="Nastavi slušati u ${applicationName}",
    cs="Pokračovat v poslechu v ${applicationName}", da="Fortsæt med at lytte i ${applicationName}",
    nl="Verder luisteren in ${applicationName}", fr="Continuer l'écoute dans ${applicationName}",
    de="Weiterhören in ${applicationName}", el="Συνέχεια ακρόασης στο ${applicationName}",
    he="המשך להאזין ב־${applicationName}", hi="${applicationName} में सुनना जारी रखें",
    hu="Folytasd a hallgatást a ${applicationName} alkalmazásban", id="Lanjutkan mendengarkan di ${applicationName}",
    it="Continua ad ascoltare in ${applicationName}", ja="${applicationName}で聴き続ける",
    ko="${applicationName}에서 계속 듣기", ms="Teruskan mendengar dalam ${applicationName}",
    nb="Fortsett å lytte i ${applicationName}", pl="Kontynuuj słuchanie w ${applicationName}",
    ptbr="Continuar ouvindo no ${applicationName}", ptpt="Continuar a ouvir no ${applicationName}",
    ro="Continuă ascultarea în ${applicationName}", ru="Продолжить слушать в ${applicationName}",
    sk="Pokračovať v počúvaní v ${applicationName}", es="Seguir escuchando en ${applicationName}",
    sv="Fortsätt lyssna i ${applicationName}", th="ฟังต่อใน ${applicationName}",
    tr="${applicationName} içinde dinlemeye devam et", uk="Продовжити слухати в ${applicationName}",
    vi="Tiếp tục nghe trong ${applicationName}", zhhs="在${applicationName}里继续听",
    zhtt="在${applicationName}裡繼續聽")

add("Next chapter in ${applicationName}", ar="الفصل التالي في ${applicationName}",
    ca="Capítol següent a ${applicationName}", hr="Sljedeće poglavlje u ${applicationName}",
    cs="Další kapitola v ${applicationName}", da="Næste kapitel i ${applicationName}",
    nl="Volgend hoofdstuk in ${applicationName}", fr="Chapitre suivant dans ${applicationName}",
    de="Nächstes Kapitel in ${applicationName}", el="Επόμενο κεφάλαιο στο ${applicationName}",
    he="הפרק הבא ב־${applicationName}", hi="${applicationName} में अगला अध्याय",
    hu="Következő fejezet a ${applicationName} alkalmazásban", id="Bab berikutnya di ${applicationName}",
    it="Capitolo successivo in ${applicationName}", ja="${applicationName}で次の章",
    ko="${applicationName}에서 다음 장", ms="Bab seterusnya dalam ${applicationName}",
    nb="Neste kapittel i ${applicationName}", pl="Następny rozdział w ${applicationName}",
    ptbr="Próximo capítulo no ${applicationName}", ptpt="Capítulo seguinte no ${applicationName}",
    ro="Capitolul următor în ${applicationName}", ru="Следующая глава в ${applicationName}",
    sk="Ďalšia kapitola v ${applicationName}", es="Siguiente capítulo en ${applicationName}",
    sv="Nästa kapitel i ${applicationName}", th="บทถัดไปใน ${applicationName}",
    tr="${applicationName} içinde sonraki bölüm", uk="Наступний розділ у ${applicationName}",
    vi="Chương tiếp theo trong ${applicationName}", zhhs="在${applicationName}里下一章",
    zhtt="在${applicationName}裡下一章")

add("Previous chapter in ${applicationName}", ar="الفصل السابق في ${applicationName}",
    ca="Capítol anterior a ${applicationName}", hr="Prethodno poglavlje u ${applicationName}",
    cs="Předchozí kapitola v ${applicationName}", da="Forrige kapitel i ${applicationName}",
    nl="Vorige hoofdstuk in ${applicationName}", fr="Chapitre précédent dans ${applicationName}",
    de="Vorheriges Kapitel in ${applicationName}", el="Προηγούμενο κεφάλαιο στο ${applicationName}",
    he="הפרק הקודם ב־${applicationName}", hi="${applicationName} में पिछला अध्याय",
    hu="Előző fejezet a ${applicationName} alkalmazásban", id="Bab sebelumnya di ${applicationName}",
    it="Capitolo precedente in ${applicationName}", ja="${applicationName}で前の章",
    ko="${applicationName}에서 이전 장", ms="Bab sebelumnya dalam ${applicationName}",
    nb="Forrige kapittel i ${applicationName}", pl="Poprzedni rozdział w ${applicationName}",
    ptbr="Capítulo anterior no ${applicationName}", ptpt="Capítulo anterior no ${applicationName}",
    ro="Capitolul anterior în ${applicationName}", ru="Предыдущая глава в ${applicationName}",
    sk="Predchádzajúca kapitola v ${applicationName}", es="Capítulo anterior en ${applicationName}",
    sv="Föregående kapitel i ${applicationName}", th="บทก่อนหน้าใน ${applicationName}",
    tr="${applicationName} içinde önceki bölüm", uk="Попередній розділ у ${applicationName}",
    vi="Chương trước trong ${applicationName}", zhhs="在${applicationName}里上一章",
    zhtt="在${applicationName}裡上一章")


# ---------------- 生成 ----------------

LITERAL = re.compile(r'\bLF?\(\s*"((?:[^"\\]|\\.)*)"')

def swift_unescape(s: str) -> str:
    return s.replace('\\"', '"').replace('\\\\', '\\')

def collect_keys() -> set[str]:
    keys: set[str] = set()
    paths = list(ROOT.glob("*.swift"))
    for folder in ("App", "Views", "Services", "Models"):
        paths.extend((ROOT / folder).rglob("*.swift"))
    for path in sorted(paths):
        if ".tmp" in str(path):
            continue
        for m in LITERAL.finditer(path.read_text(encoding="utf-8")):
            keys.add(swift_unescape(m.group(1)))
    return keys

# L() 的参数是运行时才算出来的（播放设置页那句 Text(L(mode.labelKey))），扫描器看不见
# 这样的键，只能手工列出来；主函数同样会回查代码里还写着这几个字面量
DYNAMIC_KEYS = ["Light", "Standard", "Heavy"]

def swift_sources(*folders: str) -> str:
    """把几个目录里的 Swift 源码拼成一大坨文本，用来回查字面量还在不在"""
    return "\n".join(p.read_text(encoding="utf-8")
                     for folder in folders
                     for p in sorted((ROOT / folder).glob("*.swift")))

def code_form(key: str) -> str:
    """把抽出来的本地化键还原成代码里的写法，用来回查字面量有没有改漏。
    系统抽取时把字符串插值换成占位符：App 名 \\(.applicationName) → ${applicationName}，
    意图参数 \\(\\.$book) → ${book}，这里反着换算回去"""
    def repl(match):
        name = match.group(1)
        # 参数插值在代码里写成 \(\.$name)，App 名写成 \(.applicationName)
        return "\\(.applicationName)" if name == "applicationName" else "\\(\\.$" + name + ")"
    return re.sub(r"\$\{(\w+)\}", repl, key)

def check_hand_listed_keys() -> None:
    """INTENT_KEYS / SHORTCUT_KEYS / DYNAMIC_KEYS 都是手工列的键：
    逐条回查代码里确实还写着这句，改名或删句子时忘了同步，这里就停"""
    intents = swift_sources("Intents")
    stale = [k for k in INTENT_KEYS + SHORTCUT_KEYS if f'"{code_form(k)}"' not in intents]
    if stale:
        sys.exit("Intents/ 里已经找不到这些文案了（改了字面量就要同步翻译表）：\n" + "\n".join(stale))
    app = swift_sources("App", "Views", "Services", "Models")
    stale = [k for k in DYNAMIC_KEYS if f'"{k}"' not in app]
    if stale:
        sys.exit("代码里已经找不到这些动态键了（L(mode.labelKey) 那一类）：\n" + "\n".join(stale))

def catalog(keys: list[str]) -> dict:
    strings = {}
    for key in keys:
        # 语言按代码字母序落，与 Xcode 回写这张表的顺序一致（照 add() 里的顺序写会让每个键都重排一遍）
        locs = {code: {"stringUnit": {"state": "translated", "value": val}} for code, val in sorted(TR[key].items())}
        strings[key] = {"extractionState": "manual", "localizations": locs}
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}

def ordered_keys(table: set[str], out: Path) -> list[str]:
    """键的顺序沿用 catalog 里已有的那份，新键按字母补在末尾。
    Xcode 自己回写这张表时不按码点排序，整份重排会让每次改文案的 diff 变成几千行，看不出真正动了什么"""
    if not out.exists():
        return sorted(table)
    kept = [k for k in json.loads(out.read_text(encoding="utf-8"))["strings"] if k in table]
    return kept + sorted(table - set(kept))

def dump(obj: dict) -> str:
    """排版对齐 Xcode 写 catalog 的样式：键与值之间是 " : "，文件末尾不留换行"""
    return json.dumps(obj, ensure_ascii=False, indent=2, separators=(",", " : "))

def write_app_shortcut_strings() -> int:
    """Siri 的说法不能用 String Catalog 那份表：AppShortcuts.xcstrings 要 iOS 17 才认，
    本 App 的部署目标是 16.4，iOS 16 只读经典的 <语言>.lproj/AppShortcuts.strings。
    所以这里逐语言落一个 .strings 到 Support/AppShortcuts/ 下（工程里是一个变体组）。
    键与值里的 ${applicationName} 是占位符，系统自己换成 App 名；
    没生成的 en 不用管：查不到词条就退回键本身，而键就是英文原句"""
    out_dir = ROOT / "Support" / "AppShortcuts"
    for code in LANGS.values():
        folder = out_dir / f"{code}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        lines = ["/* 由 tools/generate_xcstrings.py 生成，别手改：改文案去那张翻译表 */"]
        for key in sorted(SHORTCUT_KEYS):
            value = TR[key].get(code, "")
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'"{key}" = "{escaped}";')
        (folder / "AppShortcuts.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    # 只留当前这张表会生成的那几份；翻译表删过语言或改过键时，别把孤儿文件留在工程里
    keep = {out_dir / f"{code}.lproj" / "AppShortcuts.strings" for code in LANGS.values()}
    for stale in out_dir.rglob("AppShortcuts.strings"):
        if stale not in keep:
            stale.unlink()
    for empty in sorted(out_dir.glob("*.lproj"), reverse=True):
        if not any(empty.iterdir()):
            empty.rmdir()
    return len(LANGS)

def main():
    keys = collect_keys() | set(DYNAMIC_KEYS)
    check_hand_listed_keys()
    missing = keys - set(TR)
    extra = set(TR) - keys - set(INTENT_KEYS) - set(SHORTCUT_KEYS)
    if missing:
        sys.exit("代码用到但翻译表缺的键：\n" + "\n".join(repr(k) for k in sorted(missing)))
    if extra:
        sys.exit("翻译表多余（代码里已不用）的键：\n" + "\n".join(repr(k) for k in sorted(extra)))

    out = ROOT / "Support" / "Localizable.xcstrings"
    table = keys | set(INTENT_KEYS)
    out.write_text(dump(catalog(ordered_keys(table, out))), encoding="utf-8")
    print(f"{out}: {len(table)} 键 × {1 + len(LANGS)} 语言（含源语言 en）")
    print(f"{ROOT / 'Support' / 'AppShortcuts'}: {len(SHORTCUT_KEYS)} 条说法 × {write_app_shortcut_strings()} 语言")

if __name__ == "__main__":
    main()
