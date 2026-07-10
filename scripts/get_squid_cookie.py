#!/usr/bin/env python3
import os
import sys
import glob
import sqlite3
import shutil
import struct
import subprocess
import re

APP_BUNDLE_ID = "com.ilczuk.mlm"
COOKIE_NAMES = ["download_captcha_verified_at", "captcha_verified_at"]
DOMAINS = ["qobuz.squid.wtf", "squid.wtf", ".squid.wtf"]

def print_banner():
    print("=" * 60)
    print(" 🦑 MLM Qobuz (Squid.wtf) Cookie Extractor 🦑")
    print("=" * 60)

def set_mlm_cookie(value):
    print(f"\n[+] Gefundener Cookie-Wert: {value}")
    success = False
    
    # 1. Write to defaults
    try:
        subprocess.run(["defaults", "write", APP_BUNDLE_ID, "squid.captcha_cookie", value], check=True)
        subprocess.run(["defaults", "write", APP_BUNDLE_ID, "squid.captcha_cookie_expired", "0"], check=True)
        print(f"✅ defaults: Cookie in com.ilczuk.mlm geschrieben.")
        success = True
    except Exception as e:
        print(f"⚠️ defaults: Fehler beim Schreiben in UserDefaults: {e}")
        
    # 2. Write to ~/Library/Application Support/MLM/.env
    app_supp_dir = os.path.expanduser("~/Library/Application Support/MLM")
    app_supp_env = os.path.join(app_supp_dir, ".env")
    try:
        os.makedirs(app_supp_dir, exist_ok=True)
        write_env_file(app_supp_env, value)
        print(f"✅ env: Cookie in Application Support .env geschrieben.")
        success = True
    except Exception as e:
        print(f"⚠️ env: Fehler beim Schreiben in Application Support .env: {e}")

    # 2b. Write to ~/Library/Containers/com.ilczuk.mlm/Data/Library/Application Support/MLM/.env (Sandbox path)
    sandbox_dir = os.path.expanduser("~/Library/Containers/com.ilczuk.mlm/Data/Library/Application Support/MLM")
    sandbox_env = os.path.join(sandbox_dir, ".env")
    try:
        os.makedirs(sandbox_dir, exist_ok=True)
        write_env_file(sandbox_env, value)
        print(f"✅ env: Cookie in Sandbox Application Support .env geschrieben.")
        success = True
    except Exception as e:
        print(f"⚠️ env: Fehler beim Schreiben in Sandbox Application Support .env: {e}")

    # 2c. Write to Sandbox defaults plist directly
    try:
        sandbox_plist = os.path.expanduser("~/Library/Containers/com.ilczuk.mlm/Data/Library/Preferences/com.ilczuk.mlm")
        subprocess.run(["defaults", "write", sandbox_plist, "squid.captcha_cookie", value], check=True)
        subprocess.run(["defaults", "write", sandbox_plist, "squid.captcha_cookie_expired", "0"], check=True)
        print(f"✅ defaults: Cookie in Sandbox com.ilczuk.mlm geschrieben.")
        success = True
    except Exception as e:
        print(f"⚠️ defaults: Fehler beim Schreiben in Sandbox UserDefaults: {e}")
        
    # 3. Write to repo root .env
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    repo_env = os.path.join(repo_root, ".env")
    if os.path.exists(repo_env) or os.path.exists(os.path.join(repo_root, ".git")):
        try:
            write_env_file(repo_env, value)
            print(f"✅ env: Cookie in Projekt-Root .env geschrieben.")
            success = True
        except Exception as e:
            print(f"⚠️ env: Fehler beim Schreiben in Projekt-Root .env: {e}")

    if success:
        print("\n✅ ERFOLG: Cookie wurde erfolgreich importiert!")
        print("   Starte die MLM App neu oder öffne die Reels Inbox, um loszulegen.")
        return True
    return False

def write_env_file(filepath, value):
    lines = []
    updated = False
    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("MLM_SQUID_CAPTCHA="):
                    lines.append(f"MLM_SQUID_CAPTCHA={value}\n")
                    updated = True
                else:
                    lines.append(line)
    if not updated:
        # Add a newline if file doesn't end with one
        if lines and not lines[-1].endswith("\n"):
            lines.append("\n")
        lines.append(f"MLM_SQUID_CAPTCHA={value}\n")
        
    with open(filepath, "w", encoding="utf-8") as f:
        f.writelines(lines)

# --- Safari binarycookies parser ---
def parse_safari_cookies():
    cookie_path = os.path.expanduser("~/Library/Cookies/Cookies.binarycookies")
    if not os.path.exists(cookie_path):
        return None
    
    print("[*] Durchsuche Safari Cookies...")
    
    # We copy to a temp location to avoid locking issues
    temp_path = "/tmp/safari_cookies.bin"
    try:
        shutil.copy2(cookie_path, temp_path)
    except:
        return None
        
    try:
        with open(temp_path, "rb") as f:
            data = f.read()
            
        if data[:4] != b"cook":
            return None
            
        num_pages = struct.unpack(">I", data[4:8])[0]
        page_sizes = []
        for i in range(num_pages):
            page_sizes.append(struct.unpack(">I", data[8 + i*4 : 12 + i*4])[0])
            
        page_offset = 8 + num_pages * 4
        for page_size in page_sizes:
            page_data = data[page_offset : page_offset + page_size]
            page_offset += page_size
            
            if len(page_data) < 12:
                continue
                
            num_cookies = struct.unpack("<I", page_data[4:8])[0]
            cookie_offsets = []
            for i in range(num_cookies):
                cookie_offsets.append(struct.unpack("<I", page_data[8 + i*4 : 12 + i*4])[0])
                
            for offset in cookie_offsets:
                cookie_data = page_data[offset:]
                if len(cookie_data) < 48:
                    continue
                cookie_size = struct.unpack("<I", cookie_data[:4])[0]
                
                # Extract domain, name, value offsets
                domain_offset = struct.unpack("<I", cookie_data[16:20])[0]
                name_offset = struct.unpack("<I", cookie_data[20:24])[0]
                value_offset = struct.unpack("<I", cookie_data[28:32])[0]
                
                def read_str(off):
                    s = []
                    while off < len(cookie_data) and cookie_data[off] != 0:
                        s.append(chr(cookie_data[off]))
                        off += 1
                    return "".join(s)
                    
                domain = read_str(domain_offset)
                name = read_str(name_offset)
                val = read_str(value_offset)
                
                if name in COOKIE_NAMES and any(d in domain for d in DOMAINS):
                    os.remove(temp_path)
                    return val
    except Exception as e:
        pass
    
    if os.path.exists(temp_path):
        os.remove(temp_path)
    return None

# --- Firefox cookies parser ---
def parse_firefox_cookies():
    profiles_path = os.path.expanduser("~/Library/Application Support/Firefox/Profiles")
    if not os.path.exists(profiles_path):
        return None
        
    print("[*] Durchsuche Firefox Cookies...")
    for db_path in glob.glob(os.path.join(profiles_path, "*/cookies.sqlite")):
        temp_db = "/tmp/firefox_cookies.sqlite"
        try:
            shutil.copy2(db_path, temp_db)
            conn = sqlite3.connect(temp_db)
            cursor = conn.cursor()
            for name in COOKIE_NAMES:
                cursor.execute("SELECT value FROM moz_cookies WHERE host LIKE '%squid.wtf' AND name = ? ORDER BY creationTime DESC", (name,))
                row = cursor.fetchone()
                if row:
                    conn.close()
                    os.remove(temp_db)
                    return row[0]
            conn.close()
            os.remove(temp_db)
        except Exception as e:
            if os.path.exists(temp_db):
                os.remove(temp_db)
    return None

# --- Chrome cookies parser ---
def parse_chrome_cookies():
    chrome_path = os.path.expanduser("~/Library/Application Support/Google/Chrome")
    if not os.path.exists(chrome_path):
        return None
        
    print("[*] Durchsuche Google Chrome...")
    
    # Chrome cookies are encrypted using macOS Keychain under "Chrome Safe Storage"
    # We can try to decrypt them if cryptography is installed, otherwise warn the user.
    cookie_dbs = glob.glob(os.path.join(chrome_path, "Default/Cookies")) + \
                 glob.glob(os.path.join(chrome_path, "Default/Network/Cookies")) + \
                 glob.glob(os.path.join(chrome_path, "Profile */Cookies")) + \
                 glob.glob(os.path.join(chrome_path, "Profile */Network/Cookies"))
                 
    for db_path in cookie_dbs:
        temp_db = "/tmp/chrome_cookies.sqlite"
        try:
            shutil.copy2(db_path, temp_db)
            conn = sqlite3.connect(temp_db)
            cursor = conn.cursor()
            for name in COOKIE_NAMES:
                cursor.execute("SELECT encrypted_value FROM cookies WHERE host_key LIKE '%squid.wtf' AND name = ? ORDER BY creation_utc DESC", (name,))
                row = cursor.fetchone()
                if row and row[0]:
                    enc_val = row[0]
                    conn.close()
                    os.remove(temp_db)
                    
                    # Try decryption if cryptography is available
                    try:
                        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
                        from cryptography.hazmat.backends import default_backend
                        import hashlib
                        
                        # 1. Get Chrome Safe Storage password from Keychain
                        cmd = ["security", "find-generic-password", "-w", "-s", "Chrome Safe Storage"]
                        pw = subprocess.check_output(cmd).strip()
                        
                        # 2. Derive key using PBKDF2 HMAC-SHA1
                        salt = b"saltysalt"
                        iv = b" " * 16
                        ciphertext = enc_val[3:]
                        
                        key = hashlib.pbkdf2_hmac("sha1", pw, salt, 1003, 16)
                        cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
                        decryptor = cipher.decryptor()
                        decrypted = decryptor.update(ciphertext) + decryptor.finalize()
                        
                        # Try to extract a 13-digit Unix millisecond timestamp (starts with 1)
                        ts_match = re.search(b"1[0-9]{12}", decrypted)
                        if ts_match:
                            return ts_match.group(0).decode("utf-8")
                            
                        # Fallback: strip PKCS7 padding and try normal UTF-8 decode
                        padding_len = decrypted[-1]
                        if 0 < padding_len <= 16:
                            decrypted = decrypted[:-padding_len]
                        return decrypted.decode("utf-8")
                    except ImportError:
                        print("   [!] Hinweis: 'cryptography' library fehlt. Kann Chrome-Cookie nicht entschlüsseln.")
                        print("       Führe 'pip install cryptography' aus, um Chrome-Entschlüsselung freizuschalten.")
                        return None
                    except Exception as e:
                        print(f"   [!] Chrome-Entschlüsselung fehlgeschlagen: {e}")
                        return None
            conn.close()
            os.remove(temp_db)
        except Exception as e:
            if os.path.exists(temp_db):
                os.remove(temp_db)
    return None

def main():
    print_banner()
    
    # 1. Try Safari
    val = parse_safari_cookies()
    if val:
        print("[+] Fündig geworden in Safari!")
        if set_mlm_cookie(val):
            return
            
    # 2. Try Firefox
    val = parse_firefox_cookies()
    if val:
        print("[+] Fündig geworden in Firefox!")
        if set_mlm_cookie(val):
            return
            
    # 3. Try Chrome
    val = parse_chrome_cookies()
    if val:
        print("[+] Fündig geworden in Google Chrome!")
        if set_mlm_cookie(val):
            return
            
    print("\n❌ LEIDER KEIN COOKIE GEFUNDEN.")
    print("-" * 60)
    print("Mögliche Ursachen:")
    print("1. Du hast qobuz.squid.wtf noch nicht im Browser besucht oder kein Captcha gelöst.")
    print("2. Der Cookie 'download_captcha_verified_at' ist abgelaufen oder gelöscht.")
    print("\nManuelle Lösung in 3 einfachen Schritten:")
    print("1. Öffne qobuz.squid.wtf")
    print("2. Öffne die Entwicklertools (⌥⌘I) -> Speicher / Storage -> Cookies.")
    print("3. Kopiere den Wert von 'download_captcha_verified_at' (z.B. 1779157770721).")
    print(f"4. Trage ihn in MLM unter Einstellungen -> Sources ein, oder führe diesen Befehl im Terminal aus:")
    print(f"   defaults write {APP_BUNDLE_ID} squid.captcha_cookie <dein_cookie_wert>")
    print("-" * 60)

if __name__ == "__main__":
    main()
