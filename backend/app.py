"""Courier Parcel Booking and Tracking - Flask backend (talks to MySQL courier_db)."""
import os
from decimal import Decimal
from flask import Flask, request, jsonify, send_from_directory
import mysql.connector
from mysql.connector import Error

app = Flask(__name__, static_folder="../frontend")
app.json.default = str   # lets Decimal / datetime go into JSON

CFG = dict(host=os.getenv("DB_HOST", "localhost"),
           user=os.getenv("DB_USER", "root"),
           password=os.getenv("DB_PASSWORD", ""),
           database=os.getenv("DB_NAME", "courier_db"),
           port=int(os.getenv("DB_PORT", 3306)))

def query(sql, args=()):
    """Run a SELECT and return rows as dictionaries."""
    conn = mysql.connector.connect(**CFG); cur = conn.cursor(dictionary=True)
    try:
        cur.execute(sql, args); return cur.fetchall()
    finally:
        cur.close(); conn.close()

def tx(work):
    """Run several statements as ONE transaction: COMMIT if all pass, else ROLLBACK."""
    conn = mysql.connector.connect(**CFG); cur = conn.cursor(dictionary=True)
    try:
        result = work(cur); conn.commit(); return result
    except Exception:
        conn.rollback(); raise
    finally:
        cur.close(); conn.close()

@app.errorhandler(Error)       # errors raised by MySQL constraints and triggers
def db_error(e): return jsonify(error=e.msg), 400

@app.errorhandler(ValueError)  # our own input validation
def bad_input(e): return jsonify(error=str(e)), 400

@app.errorhandler(KeyError)
def missing(e): return jsonify(error=f"Missing field: {e}"), 400

@app.get("/")
def home(): return send_from_directory(app.static_folder, "index.html")

@app.get("/api/lookups")
def lookups():
    return jsonify(
        customers=query("SELECT cust_id, cust_name FROM Customer ORDER BY cust_name"),
        services=query("SELECT service_id, service_name, base_charge, per_kg_charge FROM ServiceType"),
        branches=query("SELECT branch_id, branch_name FROM Branch"),
        hubs=query("SELECT hub_id, hub_name FROM Hub"),
        agents=query("SELECT agent_id, agent_name FROM DeliveryAgent"))

@app.get("/api/parcels")
def parcels():
    q = "%" + request.args.get("q", "") + "%"
    return jsonify(query("""
        SELECT p.tracking_no, c.cust_name, b.dest_city, p.weight_kg, p.status,
               IFNULL(a.agent_name,'-') AS agent, b.expected_delivery,
               (SELECT IFNULL(SUM(amount),0) FROM Charge  WHERE booking_id=b.booking_id) AS charge,
               (SELECT IFNULL(SUM(amount),0) FROM Payment WHERE booking_id=b.booking_id) AS paid
        FROM Parcel p JOIN Booking b ON b.booking_id=p.booking_id
        JOIN Customer c ON c.cust_id=b.cust_id
        LEFT JOIN DeliveryAgent a ON a.agent_id=p.agent_id
        WHERE p.tracking_no LIKE %s OR c.cust_name LIKE %s ORDER BY p.parcel_id DESC""", (q, q)))

@app.post("/api/book")
def book():
    d = request.json; w = Decimal(str(d["weight_kg"]))
    if w <= 0: raise ValueError("Weight must be a positive number")
    def work(cur):
        cur.execute("SELECT * FROM ServiceType WHERE service_id=%s", (d["service_id"],))
        s = cur.fetchone()
        cur.execute("""INSERT INTO Booking (cust_id, service_id, origin_branch_id, dest_city, expected_delivery)
                       VALUES (%s,%s,%s,%s, DATE_ADD(CURDATE(), INTERVAL %s DAY))""",
                    (d["cust_id"], s["service_id"], d["branch_id"], d["dest_city"], s["max_days"]))
        bid = cur.lastrowid
        cur.execute("INSERT INTO Parcel (booking_id, tracking_no, weight_kg, description) VALUES (%s, UUID_SHORT(), %s, %s)",
                    (bid, w, d.get("description")))
        pid = cur.lastrowid; track = f"TRK{1000 + pid}"
        cur.execute("UPDATE Parcel SET tracking_no=%s WHERE parcel_id=%s", (track, pid))
        weight_charge = s["per_kg_charge"] * w
        cur.execute("INSERT INTO Charge (booking_id, description, amount) VALUES (%s,'Base charge',%s),(%s,'Weight charge',%s)",
                    (bid, s["base_charge"], bid, weight_charge))
        cur.execute("INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, scan_type) VALUES (%s,1,%s,'BOOKED')",
                    (pid, d["branch_id"]))
        return dict(tracking_no=track, total_charge=s["base_charge"] + weight_charge)
    return jsonify(tx(work))

@app.get("/api/track/<tracking_no>")
def track(tracking_no):
    rows = query("""SELECT s.seq_no, s.scan_type, COALESCE(br.branch_name,h.hub_name) AS location, s.scan_time
                    FROM ScanEvent s JOIN Parcel p ON p.parcel_id=s.parcel_id
                    LEFT JOIN Branch br ON br.branch_id=s.branch_id LEFT JOIN Hub h ON h.hub_id=s.hub_id
                    WHERE p.tracking_no=%s ORDER BY s.seq_no""", (tracking_no,))
    if not rows: raise ValueError("Tracking number not found")
    return jsonify(rows)

@app.post("/api/scan")
def scan():
    d = request.json
    kind, loc_id = d["location"].split(":")      # "B:1" = branch 1, "H:2" = hub 2
    def work(cur):
        cur.execute("SELECT parcel_id, agent_id FROM Parcel WHERE tracking_no=%s", (d["tracking_no"],))
        p = cur.fetchone()
        if not p: raise ValueError("Tracking number not found")
        cur.execute("SELECT IFNULL(MAX(seq_no),0)+1 AS n FROM ScanEvent WHERE parcel_id=%s", (p["parcel_id"],))
        seq = cur.fetchone()["n"]
        cur.execute("INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type) VALUES (%s,%s,%s,%s,%s)",
                    (p["parcel_id"], seq, loc_id if kind == "B" else None, loc_id if kind == "H" else None, d["scan_type"]))
        if d["scan_type"] in ("DELIVERED", "FAILED_ATTEMPT"):      # delivery update / failed attempt
            if not p["agent_id"]: raise ValueError("Assign a delivery agent first")
            cur.execute("SELECT COUNT(*)+1 AS n FROM DeliveryAttempt WHERE parcel_id=%s", (p["parcel_id"],))
            cur.execute("INSERT INTO DeliveryAttempt (parcel_id, agent_id, attempt_no, result, reason) VALUES (%s,%s,%s,%s,%s)",
                        (p["parcel_id"], p["agent_id"], cur.fetchone()["n"],
                         "SUCCESS" if d["scan_type"] == "DELIVERED" else "FAILED", d.get("reason")))
        return dict(seq_no=seq)
    return jsonify(tx(work))

@app.post("/api/pay")
def pay():
    d = request.json
    def work(cur):
        cur.execute("""INSERT INTO Payment (booking_id, amount, method)
                       SELECT booking_id, %s, %s FROM Parcel WHERE tracking_no=%s""",
                    (d["amount"], d["method"], d["tracking_no"]))
        if cur.rowcount == 0: raise ValueError("Tracking number not found")
        return dict(ok=True)
    return jsonify(tx(work))

@app.post("/api/assign")
def assign():
    d = request.json
    def work(cur):
        cur.execute("UPDATE Parcel SET agent_id=%s WHERE tracking_no=%s", (d["agent_id"], d["tracking_no"]))
        if cur.rowcount == 0: raise ValueError("Tracking number not found (or agent unchanged)")
        return dict(ok=True)
    return jsonify(tx(work))

@app.get("/api/customers")
def customers(): return jsonify(query("SELECT * FROM Customer ORDER BY cust_id"))

@app.post("/api/customers")
def add_customer():
    d = request.json
    if not d["cust_name"].strip() or not d["phone"].strip(): raise ValueError("Name and phone are required")
    return jsonify(tx(lambda cur: cur.execute(
        "INSERT INTO Customer (cust_name, phone, email, address) VALUES (%s,%s,%s,%s)",
        (d["cust_name"], d["phone"], d.get("email"), d["address"])) or dict(ok=True)))

@app.delete("/api/customers/<int:cid>")
def del_customer(cid):
    return jsonify(tx(lambda cur: cur.execute("DELETE FROM Customer WHERE cust_id=%s", (cid,)) or dict(ok=True)))

VIEWS = dict(location="v_current_location", delayed="v_delayed_shipments", branch="v_branch_load",
             route="v_route_performance", failed="v_failed_attempts", revenue="v_revenue")

@app.get("/api/reports/<name>")
def report(name):
    if name not in VIEWS: raise ValueError("Unknown report")
    return jsonify(query(f"SELECT * FROM {VIEWS[name]}"))

if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=True)
