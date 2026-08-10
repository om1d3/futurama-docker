#!/usr/bin/env python3
import os
import time
import json
import requests
import re
from datetime import datetime
from flask import Flask, render_template_string, request
from playwright.sync_api import sync_playwright
from threading import Thread

def load_config():
    config = {}
    config_file = '/app/limdius.conf'
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip()
    return config

config = load_config()
def get_config(key, default=''):
    return config.get(key, os.getenv(key, default))

# Configuration
NTFY_SERVER = get_config('NTFY_SERVER', 'http://192.168.21.130:8888')
NTFY_TOPIC = get_config('NTFY_TOPIC', 'tiguan-deals')
MAKE = get_config('MAKE', 'volkswagen').lower()
MODEL = get_config('MODEL', 'tiguan').lower()
MIN_PRICE = int(get_config('MIN_PRICE', '1000'))
MAX_PRICE = int(get_config('MAX_PRICE', '9000'))
MAX_KM = int(get_config('MAX_KM', '150000'))
CHECK_INTERVAL = int(get_config('CHECK_INTERVAL', '3600'))
WEB_PORT = int(get_config('WEB_PORT', '5050'))
WEB_HOST = get_config('WEB_HOST', 'http://192.168.21.130:5050')
PLAYWRIGHT_URL = get_config('PLAYWRIGHT_DRIVER_URL', 'ws://playwright-chrome:3000')
POSTAL_CODE = get_config('POSTAL_CODE', 'L7L7M3')
RADIUS = get_config('RADIUS', '1000')

# Global state
current_listings = []
last_check = None
check_count = 0
scrape_in_progress = False
app = Flask(__name__)

HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Limdius v250</title>
    <meta http-equiv="refresh" content="60">
    <style>
        body{font-family:Arial,sans-serif;max-width:1200px;margin:0 auto;padding:20px;background:#0d1117;color:#c9d1d9;}
        .header{background:#161b22;padding:20px;border-radius:8px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,0.5);border:1px solid #30363d;display:flex;justify-content:space-between;align-items:center;}
        .header-buttons{display:flex;gap:10px;}
        a.settings-link,a.debug-link{padding:8px 16px;background:#238636;color:white;text-decoration:none;border-radius:6px;font-size:14px;}
        a.debug-link{background:#30363d;}
        a.settings-link:hover{background:#2ea043;}
        a.debug-link:hover{background:#484f58;}
        .config-box{background:#161b22;padding:15px;border-radius:8px;margin-bottom:20px;border:1px solid #30363d;}
        .config-item{display:inline-block;margin-right:20px;color:#8b949e;font-size:14px;}
        .config-value{color:#58a6ff;font-weight:bold;}
        .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px;margin-bottom:20px;}
        .stat-card{background:#161b22;padding:15px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,0.5);border:1px solid #30363d;}
        .stat-label{color:#8b949e;font-size:12px;text-transform:uppercase;}
        .stat-value{font-size:24px;font-weight:bold;color:#c9d1d9;}
        .listing{background:#161b22;padding:20px;margin-bottom:15px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,0.5);border:1px solid #30363d;border-left:4px solid #3fb950;}
        .listing.new{border-left-color:#58a6ff;animation:highlight 2s;}
        @keyframes highlight{from{background:#1c2128;}to{background:#161b22;}}
        .listing-title{font-size:18px;font-weight:bold;margin-bottom:10px;color:#e6edf3;}
        .listing-details{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:10px 0;}
        .detail{display:flex;flex-direction:column;}
        .detail-label{font-size:11px;color:#8b949e;text-transform:uppercase;}
        .detail-value{font-size:16px;color:#c9d1d9;font-weight:500;}
        .price{color:#3fb950;}
        .km{color:#f85149;}
        .year{color:#58a6ff;}
        .listing-link{display:inline-block;margin-top:10px;padding:8px 16px;background:#238636;color:white;text-decoration:none;border-radius:6px;}
        .listing-link:hover{background:#2ea043;}
        h1{margin:0;color:#e6edf3;}
        h2{color:#8b949e;margin-top:30px;}
    </style>
</head>
<body>
    <div class="header">
        <h1>🚗 Limdius v250 - {{ make|title }} {{ model|title }}</h1>
        <div class="header-buttons">
            <a href="/debug" class="debug-link">🐛 Debug</a>
            <a href="/settings" class="settings-link">⚙️ Settings</a>
        </div>
    </div>
    
    <div class="config-box">
        <div class="config-item">Price: <span class="config-value">${{ "{:,.0f}".format(min_price) }} - ${{ "{:,.0f}".format(max_price) }}</span></div>
        <div class="config-item">Max KM: <span class="config-value">{{ "{:,.0f}".format(max_km) }}</span></div>
        {% if postal_code %}
        <div class="config-item">Location: <span class="config-value">{{ postal_code }}{% if radius %} (+{{ radius }}km){% else %} (Provincial){% endif %}</span></div>
        {% else %}
        <div class="config-item">Location: <span class="config-value">National</span></div>
        {% endif %}
        <div class="config-item">Check: <span class="config-value">{{ (check_interval/3600)|round(1) }}h</span></div>
    </div>
    
    <div class="stats">
        <div class="stat-card">
            <div class="stat-label">Active Listings</div>
            <div class="stat-value">{{ listings|length }}</div>
        </div>
        <div class="stat-card">
            <div class="stat-label">Last Check</div>
            <div class="stat-value" style="font-size:14px;">{{ last_check or 'Not yet' }}</div>
        </div>
        <div class="stat-card">
            <div class="stat-label">Total Checks</div>
            <div class="stat-value">{{ check_count }}</div>
        </div>
    </div>

    <h2>Current Listings ({{ listings|length }})</h2>
    
    {% if listings %}
        {% for listing in listings %}
        <div class="listing {% if listing.is_new %}new{% endif %}">
            <div class="listing-title">{{ listing.title }}</div>
            <div class="listing-details">
                <div class="detail">
                    <span class="detail-label">Price</span>
                    <span class="detail-value price">${{ "{:,.0f}".format(listing.price) }}</span>
                </div>
                <div class="detail">
                    <span class="detail-label">Odometer</span>
                    <span class="detail-value km">{{ "{:,.0f}".format(listing.km) }} km</span>
                </div>
                <div class="detail">
                    <span class="detail-label">Year</span>
                    <span class="detail-value year">{{ listing.year }}</span>
                </div>
                {% if listing.location %}
                <div class="detail">
                    <span class="detail-label">Location</span>
                    <span class="detail-value">{{ listing.location }}</span>
                </div>
                {% endif %}
            </div>
            <a href="{{ listing.url }}" target="_blank" class="listing-link">View on AutoTrader →</a>
        </div>
        {% endfor %}
    {% else %}
        <p style="text-align:center;padding:40px;color:#8b949e;">No listings found matching criteria</p>
    {% endif %}
</body>
</html>
'''

SETTINGS_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Settings - Limdius v250</title>
    <style>
        body{font-family:Arial,sans-serif;max-width:800px;margin:0 auto;padding:20px;background:#0d1117;color:#c9d1d9;}
        .header{background:#161b22;padding:20px;border-radius:8px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,0.5);border:1px solid #30363d;display:flex;justify-content:space-between;align-items:center;}
        h1{margin:0;color:#e6edf3;}
        .back-link{padding:8px 16px;background:#238636;color:white;text-decoration:none;border-radius:6px;}
        .back-link:hover{background:#2ea043;}
        .form-container{background:#161b22;padding:30px;border-radius:8px;border:1px solid #30363d;}
        .form-group{margin-bottom:20px;}
        label{display:block;margin-bottom:5px;color:#8b949e;font-size:14px;font-weight:500;}
        input,select{width:100%;padding:10px;background:#0d1117;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;box-sizing:border-box;}
        input:focus,select:focus{outline:none;border-color:#58a6ff;}
        .help-text{font-size:12px;color:#8b949e;margin-top:5px;}
        button{padding:10px 20px;border:none;border-radius:6px;background:#238636;color:white;width:100%;cursor:pointer;font-weight:500;}
        button:hover{background:#2ea043;}
        .alert{padding:15px;border-radius:6px;margin-bottom:20px;border-left:4px solid #3fb950;background:#1c2128;color:#3fb950;}
    </style>
</head>
<body>
    <div class="header">
        <h1>⚙️ Settings</h1>
        <a href="/" class="back-link">← Back</a>
    </div>
    {% if saved %}<div class="alert">✓ Saved! Restart: <code style="background:#0d1117;padding:2px 6px;">docker restart limdius</code></div>{% endif %}
    <div class="form-container">
        <form method="POST">
            <div class="form-group"><label>Make</label><input name="MAKE" value="{{ config.MAKE }}" required><div class="help-text">e.g., volkswagen, honda</div></div>
            <div class="form-group"><label>Model</label><input name="MODEL" value="{{ config.MODEL }}" required><div class="help-text">e.g., tiguan, civic</div></div>
            <div class="form-group"><label>Min Price (CAD)</label><input type="number" name="MIN_PRICE" value="{{ config.MIN_PRICE }}" required></div>
            <div class="form-group"><label>Max Price (CAD)</label><input type="number" name="MAX_PRICE" value="{{ config.MAX_PRICE }}" required></div>
            <div class="form-group"><label>Max Kilometers</label><input type="number" name="MAX_KM" value="{{ config.MAX_KM }}" required></div>
            <div class="form-group"><label>Postal Code</label><input name="POSTAL_CODE" value="{{ config.POSTAL_CODE }}"><div class="help-text">Leave empty for National</div></div>
            <div class="form-group"><label>Search Radius</label><select name="RADIUS">
                <option value="" {% if not config.RADIUS %}selected{% endif %}>National</option>
                <option value="25" {% if config.RADIUS=="25" %}selected{% endif %}>25 km</option>
                <option value="50" {% if config.RADIUS=="50" %}selected{% endif %}>50 km</option>
                <option value="100" {% if config.RADIUS=="100" %}selected{% endif %}>100 km</option>
                <option value="250" {% if config.RADIUS=="250" %}selected{% endif %}>250 km</option>
                <option value="500" {% if config.RADIUS=="500" %}selected{% endif %}>500 km</option>
                <option value="1000" {% if config.RADIUS=="1000" %}selected{% endif %}>1000 km</option>
                <option value="provincial" {% if config.RADIUS=="provincial" %}selected{% endif %}>Provincial</option>
            </select></div>
            <div class="form-group"><label>Check Interval (seconds)</label><input type="number" name="CHECK_INTERVAL" value="{{ config.CHECK_INTERVAL }}" required><div class="help-text">3600 = 1 hour</div></div>
            <div class="form-group"><label>NTFY Server</label><input name="NTFY_SERVER" value="{{ config.NTFY_SERVER }}"></div>
            <div class="form-group"><label>NTFY Topic</label><input name="NTFY_TOPIC" value="{{ config.NTFY_TOPIC }}"></div>
            <button type="submit">💾 Save Settings</button>
        </form>
    </div>
</body>
</html>
'''

current_listings = []
last_check = None
check_count = 0
scrape_in_progress = False
app = Flask(__name__)

def send_notification(title, message, url=None):
    try:
        data = {"topic": NTFY_TOPIC, "title": title, "message": message, "priority": 4, "tags": ["car"]}
        if url:
            data["click"] = url
            data["actions"] = [{"action": "view", "label": "View", "url": url}]
        requests.post(f"{NTFY_SERVER}/{NTFY_TOPIC}", json=data, timeout=10)
        return True
    except:
        return False

def scrape_autotrader():
    """PRODUCTION-READY scraper - processes elements immediately per page"""
    global current_listings, last_check, check_count, scrape_in_progress
    scrape_in_progress = True
    
    # Build URL based on location settings
    url = f"https://www.autotrader.ca/cars/{MAKE}/{MODEL}/"
    params = [f"oRng=,{MAX_KM}", f"pRng={MIN_PRICE},{MAX_PRICE}"]
    
    if POSTAL_CODE:
        clean_postal = POSTAL_CODE.replace(' ', '')
        if RADIUS and RADIUS != 'provincial':
            # Specific radius
            params.append(f"loc={clean_postal}")
            params.append(f"prx={RADIUS}")
        elif RADIUS == 'provincial' or not RADIUS:
            # Provincial search
            province_map = {'L':'on','M':'on','N':'on','P':'on','K':'on','H':'qc','J':'qc','G':'qc','V':'bc','T':'ab','S':'sk','R':'mb','E':'nb','B':'ns','C':'pe','A':'nl'}
            prov = province_map.get(clean_postal[0].upper() if clean_postal else '', 'on')
            params.append(f"prv={prov}")
    
    url += '?' + '&'.join(params)
    
    print(f"\n{'='*80}")
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Limdius v250")
    print(f"  URL: {url}")
    print(f"{'='*80}\n")
    
    new_listings = []
    stats = {'total':0,'ok':0,'promo':0,'no_price':0,'price_low':0,'price_high':0,'km_high':0,'no_url':0,'dup':0}
    
    try:
        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(PLAYWRIGHT_URL)
            context = browser.new_context(
                viewport={'width': 1920, 'height': 1080},
                user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                locale='en-CA',
                timezone_id='America/Toronto'
            )
            page = context.new_page()
            page.add_init_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined}); window.chrome = {runtime: {}};")
            
            # Get cookies
            print("  [COOKIES] Getting...")
            page.goto('https://www.autotrader.ca/', wait_until='domcontentloaded', timeout=30000)
            time.sleep(3)
            
            # PROCESS EACH PAGE IMMEDIATELY (proven working method)
            for page_num in range(1, 4):
                page_url = url if page_num == 1 else f"{url}&rcp={15*(page_num-1)}"
                
                print(f"\n  [PAGE {page_num}] Loading...")
                page.goto(page_url, wait_until='domcontentloaded', timeout=60000)
                time.sleep(10 if page_num == 1 else 8)
                
                # Scroll only page 1
                if page_num == 1:
                    print(f"  [PAGE {page_num}] Scrolling...")
                    for i in range(15):
                        page.evaluate("window.scrollTo({top: document.body.scrollHeight, behavior: 'smooth'})")
                        time.sleep(3)
                    page.evaluate("window.scrollTo({top: 0, behavior: 'smooth'})")
                    time.sleep(3)
                    page.evaluate("window.scrollTo({top: document.body.scrollHeight + 2000, behavior: 'smooth'})")
                    time.sleep(10)
                
                # Find elements
                elements = None
                for selector in ['[class*="listing"]', '[data-testid="listing-card"]', '.result-item']:
                    try:
                        elems = page.query_selector_all(selector)
                        if elems:
                            elements = elems
                            print(f"  [PAGE {page_num}] ✓ {len(elements)} elements: {selector}")
                            break
                    except:
                        continue
                
                if not elements:
                    print(f"  [PAGE {page_num}] No elements")
                    continue
                
                # PROCESS IMMEDIATELY while still on this page
                print(f"  [PAGE {page_num}] Processing NOW...")
                page_added = 0
                stats['total'] += len(elements)
                
                for elem in elements:
                    try:
                        # Get text
                        text = elem.inner_text()
                        
                        # Skip promo
                        if 'similar vehicles' in text.lower() or 'explore similar' in text.lower():
                            stats['promo'] += 1
                            continue
                        
                        # Get link
                        link = elem.query_selector('a[href*="/a/"]')
                        if not link:
                            stats['no_url'] += 1
                            continue
                        
                        href = link.get_attribute('href')
                        if not href or '/offers/' in href:
                            stats['no_url'] += 1
                            continue
                        
                        listing_url = href if href.startswith('http') else f"https://www.autotrader.ca{href}"
                        
                        # Extract ID from URL
                        listing_id = href.rstrip('/').split('/')[-1] or href.rstrip('/').split('/')[-2]
                        
                        if len(listing_id) < 5:
                            stats['no_url'] += 1
                            continue
                        
                        # Already added?
                        if any(l['id'] == listing_id for l in new_listings):
                            stats['dup'] += 1
                            continue
                        
                        # Extract PRICE
                        price = None
                        # Try multiple price selectors
                        for price_sel in ['[class*="price"]', '[data-testid*="price"]', '.price', 'span[class*="Price"]', 'p[class*="price"]', 'div[class*="price"]']:
                            try:
                                price_elem = elem.query_selector(price_sel)
                                if price_elem:
                                    price_text = price_elem.inner_text().strip()
                                    match = re.search(r'\$\s*([\d,]+)', price_text)
                                    if match:
                                        price = int(match.group(1).replace(',', ''))
                                        break
                            except:
                                continue
                        
                        # Fallback: regex on full text
                        if not price:
                            matches = re.findall(r'\$\s*([\d,]+)', text)
                            for match in matches:
                                p = int(match.replace(',', ''))
                                if 500 <= p <= 500000:
                                    price = p
                                    break
                        
                        if not price:
                            stats['no_price'] += 1
                            continue
                        
                        if price < MIN_PRICE:
                            stats['price_low'] += 1
                            continue
                        if price > MAX_PRICE:
                            stats['price_high'] += 1
                            continue
                        
                        # Extract KM (odometer, not distance)
                        km = 0
                        # Try km selectors
                        for km_sel in ['[class*="odometer"]', '[class*="mileage"]', '[class*="km"]', 'span:has-text("km")']:
                            try:
                                km_elem = elem.query_selector(km_sel)
                                if km_elem:
                                    km_text = km_elem.inner_text().strip()
                                    match = re.search(r'([\d,]+)', km_text)
                                    if match:
                                        km_val = int(match.group(1).replace(',', ''))
                                        if km_val >= 1000:  # Real odometer
                                            km = km_val
                                            break
                            except:
                                continue
                        
                        # Fallback: find largest km value in text (likely odometer)
                        if km == 0:
                            km_matches = re.findall(r'(\d{1,3}(?:,\d{3})*)\s*km', text, re.IGNORECASE)
                            for match in km_matches:
                                km_val = int(match.replace(',', ''))
                                if km_val >= 10000:  # Odometer reading
                                    km = km_val
                                    break
                            # Lower mileage fallback
                            if km == 0:
                                for match in km_matches:
                                    km_val = int(match.replace(',', ''))
                                    if 1000 <= km_val < 10000:
                                        km = km_val
                                        break
                        
                        if km > MAX_KM and km > 0:
                            stats['km_high'] += 1
                            continue
                        
                        # Extract TITLE
                        title_elem = elem.query_selector('h2, h3, [class*="title"]')
                        title = title_elem.inner_text().strip() if title_elem else text.split('\n')[0][:50]
                        
                        # Extract YEAR from title
                        year = "N/A"
                        year_nums = [int(s) for s in title.split() if s.isdigit() and len(s)==4 and 1990<=int(s)<=2030]
                        if year_nums:
                            year = str(year_nums[0])
                        else:
                            # Fallback: search text
                            year_match = re.search(r'\b(20[0-2][0-9]|19[9][0-9])\b', text)
                            if year_match:
                                year = year_match.group(1)
                        
                        # Extract LOCATION
                        location = ""
                        loc_elem = elem.query_selector('[class*="location"]')
                        if loc_elem:
                            location = loc_elem.inner_text().strip()
                        else:
                            loc_match = re.search(r'(\d+)\s*km\s+from', text, re.IGNORECASE)
                            if loc_match:
                                location = f"{loc_match.group(1)}km away"
                        
                        # Create listing
                        listing = {
                            'title': title,
                            'price': price,
                            'km': km,
                            'year': year,
                            'location': location,
                            'url': listing_url,
                            'id': listing_id,
                            'is_new': False
                        }
                        
                        new_listings.append(listing)
                        page_added += 1
                        stats['ok'] += 1
                        print(f"    ✓ ${price:,} | {km:,}km | {year} | {listing_id}")
                        
                    except Exception as e:
                        continue
                
                print(f"  [PAGE {page_num}] Added {page_added} listings")
            
            page.close()
            context.close()
            browser.close()
            
            # Print stats
            print(f"\n  {'='*76}")
            print(f"  ╔═══ Final Stats ═══╗")
            print(f"  ║ Total:   {stats['total']:3d} ║")
            print(f"  ║ ✓ OK:       {stats['ok']:3d} ║")
            print(f"  ║ ✗ Promo:    {stats['promo']:3d} ║")
            print(f"  ║ ✗ NoPrice:{stats['no_price']:3d} ║")
            print(f"  ║ ✗ P<{MIN_PRICE}:     {stats['price_low']:3d} ║")
            print(f"  ║ ✗ P>{MAX_PRICE}:   {stats['price_high']:3d} ║")
            print(f"  ║ ✗ KM>{MAX_KM}:  {stats['km_high']:3d} ║")
            print(f"  ║ ✗ NoURL:   {stats['no_url']:3d} ║")
            print(f"  ║ ✗ Dup:      {stats['dup']:3d} ║")
            print(f"  ╚════════════════════╝")
            print(f"  {'='*76}\n")
            
            # Check for changes
            old_ids = {l['id'] for l in current_listings}
            new_ids = {l['id'] for l in new_listings}
            added_ids = new_ids - old_ids
            removed_ids = old_ids - new_ids
            
            if check_count == 0:
                print(f"  🎉 First check - found {len(new_listings)} listings\n")
            elif added_ids:
                print(f"  🆕 NEW LISTINGS: {len(added_ids)}")
                for listing in new_listings:
                    if listing['id'] in added_ids:
                        listing['is_new'] = True
                        print(f"    + {listing['title']} - ${listing['price']:,}")
                        send_notification(
                            f"🚗 New {MAKE.title()} {MODEL.title()}",
                            f"{listing['title']}\n${listing['price']:,.0f} • {listing['km']:,.0f}km",
                            listing['url']
                        )
            
            if removed_ids:
                print(f"  📤 REMOVED: {len(removed_ids)}\n")
            
            if not added_ids and not removed_ids and check_count > 0:
                print(f"  ✓ No changes: {len(new_listings)} listings\n")
            
            current_listings = new_listings
            last_check = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            check_count += 1
            
    except Exception as e:
        print(f"  ❌ Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        scrape_in_progress = False

def monitor_loop():
    print("="*80)
    print(f"🚗 Limdius v250 Production - {MAKE.title()} {MODEL.title()}")
    print("="*80)
    print(f"  Make/Model: {MAKE.title()} {MODEL.title()}")
    print(f"  Price: ${MIN_PRICE:,} - ${MAX_PRICE:,}")
    print(f"  Max KM: {MAX_KM:,}")
    if POSTAL_CODE and RADIUS and RADIUS != 'provincial':
        print(f"  Location: {POSTAL_CODE} (+{RADIUS}km)")
    elif POSTAL_CODE:
        print(f"  Location: Provincial ({POSTAL_CODE})")
    else:
        print(f"  Location: National")
    print(f"  Check: Every {CHECK_INTERVAL}s ({CHECK_INTERVAL/3600:.1f}h)")
    print(f"  Web: {WEB_HOST}")
    print(f"  NTFY: {NTFY_SERVER}/{NTFY_TOPIC}")
    print("="*80 + "\n")
    
    while True:
        try:
            scrape_autotrader()
            print(f"  💤 Sleeping {CHECK_INTERVAL}s...\n")
            time.sleep(CHECK_INTERVAL)
        except KeyboardInterrupt:
            print("\n👋 Shutting down...")
            break
        except Exception as e:
            print(f"  ❌ Loop error: {e}")
            time.sleep(60)

@app.route('/')
def index():
    s = sorted(current_listings, key=lambda x: (x.get('price',999999), x.get('km',999999), -int(x.get('year','0')) if str(x.get('year','0')).isdigit() else 0))
    
    location_filter = ""
    if POSTAL_CODE and RADIUS and RADIUS != 'provincial':
        location_filter = f"{POSTAL_CODE} (+{RADIUS}km)"
    elif POSTAL_CODE:
        location_filter = f"{POSTAL_CODE} (Provincial)"
    
    return render_template_string(HTML_TEMPLATE, listings=s, make=MAKE, model=MODEL, min_price=MIN_PRICE, max_price=MAX_PRICE, max_km=MAX_KM, postal_code=POSTAL_CODE, radius=RADIUS, check_interval=CHECK_INTERVAL, last_check=last_check, check_count=check_count, location_filter=location_filter)

@app.route('/debug')
def debug():
    info = {
        'Version': 'v250 Production',
        'Make': MAKE, 'Model': MODEL,
        'Min Price': MIN_PRICE, 'Max Price': MAX_PRICE, 'Max KM': MAX_KM,
        'Postal Code': POSTAL_CODE, 'Radius': RADIUS,
        'Check Interval': CHECK_INTERVAL,
        'NTFY Server': NTFY_SERVER, 'NTFY Topic': NTFY_TOPIC,
        'Active Listings': len(current_listings),
        'Last Check': last_check,
        'Check Count': check_count,
        'Listing IDs': [{'id': l['id'], 'price': l['price'], 'km': l['km']} for l in current_listings]
    }
    html = f"<html><head><style>body{{background:#0d1117;color:#c9d1d9;padding:20px;font-family:monospace;}}pre{{background:#161b22;padding:20px;border-radius:8px;border:1px solid #30363d;}}</style></head><body><h1 style='color:#e6edf3;'>🐛 Limdius v250 Debug</h1><a href='/' style='color:#58a6ff;text-decoration:none;'>← Back to Limdius</a><pre>{json.dumps(info, indent=2)}</pre></body></html>"
    return html

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    saved = False
    if request.method == 'POST':
        try:
            with open('/app/limdius.conf', 'w') as f:
                f.write("# Limdius v250 Production Configuration\n")
                f.write("# AutoTrader.ca Vehicle Monitor\n\n")
                for key in ['MAKE', 'MODEL', 'MIN_PRICE', 'MAX_PRICE', 'MAX_KM', 'POSTAL_CODE', 'RADIUS', 'CHECK_INTERVAL', 'NTFY_SERVER', 'NTFY_TOPIC']:
                    value = request.form.get(key, '')
                    if key == 'RADIUS' and value == '':
                        value = ''  # National search
                    f.write(f"{key}={value}\n")
                f.write(f"\nWEB_PORT={WEB_PORT}\n")
                f.write(f"WEB_HOST={WEB_HOST}\n")
                f.write(f"PLAYWRIGHT_DRIVER_URL={PLAYWRIGHT_URL}\n")
            saved = True
        except Exception as e:
            print(f"❌ Save error: {e}")
    
    cfg = {
        'MAKE': MAKE, 'MODEL': MODEL,
        'MIN_PRICE': MIN_PRICE, 'MAX_PRICE': MAX_PRICE, 'MAX_KM': MAX_KM,
        'POSTAL_CODE': POSTAL_CODE, 'RADIUS': str(RADIUS) if RADIUS else '',
        'CHECK_INTERVAL': CHECK_INTERVAL,
        'NTFY_SERVER': NTFY_SERVER, 'NTFY_TOPIC': NTFY_TOPIC
    }
    return render_template_string(SETTINGS_TEMPLATE, config=cfg, saved=saved)

def run_flask():
    print(f"✓ Web server on port {WEB_PORT}")
    app.run(host='0.0.0.0', port=WEB_PORT, debug=False, use_reloader=False)

if __name__ == '__main__':
    Thread(target=run_flask, daemon=True).start()
    time.sleep(2)
    monitor_loop()

# Limdius v250 - Production Ready
# Proven extraction method: process elements immediately per page
# Scalable: 25km → National, full UI, robust filtering
