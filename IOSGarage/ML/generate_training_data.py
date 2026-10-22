"""Generates synthetic CSVs so you can train Core ML models before you have real data.
Replace with exported real service/appointment history as it accumulates.
Usage: python3 generate_training_data.py  ->  maintenance.csv, noshow.csv"""
import csv, random
random.seed(42)

COMPONENTS = {  # name: (interval_km, interval_months)
    "Oil Change": (10000, 6), "Brake Service": (40000, 24), "Tyres": (50000, 36),
    "Battery": (60000, 48), "Air Filter": (20000, 12), "Coolant Flush": (40000, 24),
}

with open("maintenance.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["component", "mileage", "ageYears", "kmSinceLast", "daysSinceLast", "avgKmPerMonth", "kmUntilDue"])
    for _ in range(20000):
        c, (ik, im) = random.choice(list(COMPONENTS.items()))
        age = random.uniform(0.5, 15)
        avg = random.uniform(400, 2500)
        mileage = age * 12 * avg
        km_since = random.uniform(0, ik * 1.3)
        days_since = min(km_since / avg * 30.4 * random.uniform(0.7, 1.4), age * 365)
        wear = random.uniform(0.85, 1.15) * (0.9 if avg > 1800 else 1.0)   # heavy use wears faster
        by_km = ik * wear - km_since
        by_time = (im * 30.4 - days_since) / 30.4 * avg
        w.writerow([c, round(mileage), round(age, 2), round(km_since), round(days_since), round(avg),
                    round(min(by_km, by_time) + random.gauss(0, ik * 0.02))])

with open("noshow.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["leadDays", "weekday", "hour", "pastBookings", "pastNoShows", "noShow"])
    for _ in range(15000):
        lead = random.expovariate(1 / 6); wd = random.randint(1, 7); hr = random.randint(8, 17)
        pb = random.randint(0, 20); pn = sum(random.random() < 0.1 for _ in range(pb))
        z = -2.4 + 0.045 * lead + 4.0 * (pn + 1) / (pb + 8) + (0.3 if wd in (1, 7) else 0) + (0.25 if hr < 9 else 0)
        p = 1 / (1 + 2.718281828 ** -z)
        w.writerow([round(lead, 1), wd, hr, pb, pn, int(random.random() < p)])
print("Wrote maintenance.csv and noshow.csv")
