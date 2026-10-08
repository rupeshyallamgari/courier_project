-- =====================================================================
-- COURIER PARCEL BOOKING AND TRACKING MANAGEMENT SYSTEM  (MySQL 8.0.16+)
-- Open Command Prompt, run:  mysql -u root -p
-- Then paste each STEP one by one at the  mysql>  prompt.
-- =====================================================================


-- ---------------------------------------------------------------------
-- STEP 1: Create and select the database
-- ---------------------------------------------------------------------
DROP DATABASE IF EXISTS courier_db;
CREATE DATABASE courier_db;
USE courier_db;


-- ---------------------------------------------------------------------
-- STEP 2: Create tables (PK, FK, UNIQUE, NOT NULL, CHECK, DEFAULT)
-- ---------------------------------------------------------------------
CREATE TABLE Customer (
  cust_id    INT PRIMARY KEY AUTO_INCREMENT,
  cust_name  VARCHAR(50) NOT NULL,
  phone      VARCHAR(15) NOT NULL UNIQUE,
  email      VARCHAR(60),
  address    VARCHAR(120) NOT NULL
);

CREATE TABLE Branch (
  branch_id    INT PRIMARY KEY AUTO_INCREMENT,
  branch_name  VARCHAR(50) NOT NULL,
  city         VARCHAR(40) NOT NULL
);

CREATE TABLE Hub (
  hub_id    INT PRIMARY KEY AUTO_INCREMENT,
  hub_name  VARCHAR(50) NOT NULL,
  city      VARCHAR(40) NOT NULL
);

CREATE TABLE ServiceType (
  service_id      INT PRIMARY KEY AUTO_INCREMENT,
  service_name    VARCHAR(30) NOT NULL UNIQUE,
  base_charge     DECIMAL(8,2) NOT NULL CHECK (base_charge > 0),
  per_kg_charge   DECIMAL(8,2) NOT NULL CHECK (per_kg_charge > 0),
  max_days        INT NOT NULL CHECK (max_days > 0)
);

CREATE TABLE DeliveryAgent (
  agent_id    INT PRIMARY KEY AUTO_INCREMENT,
  agent_name  VARCHAR(50) NOT NULL,
  phone       VARCHAR(15) NOT NULL UNIQUE,
  branch_id   INT NOT NULL,
  FOREIGN KEY (branch_id) REFERENCES Branch(branch_id)
);

CREATE TABLE Vehicle (
  vehicle_id    INT PRIMARY KEY AUTO_INCREMENT,
  reg_no        VARCHAR(15) NOT NULL UNIQUE,
  vehicle_type  VARCHAR(20) NOT NULL,
  capacity_kg   INT NOT NULL CHECK (capacity_kg > 0)
);

CREATE TABLE Route (
  route_id      INT PRIMARY KEY AUTO_INCREMENT,
  route_name    VARCHAR(40) NOT NULL,
  from_hub_id   INT NOT NULL,
  to_hub_id     INT NOT NULL,
  distance_km   INT NOT NULL CHECK (distance_km > 0),
  vehicle_id    INT NOT NULL,
  FOREIGN KEY (from_hub_id) REFERENCES Hub(hub_id),
  FOREIGN KEY (to_hub_id)   REFERENCES Hub(hub_id),
  FOREIGN KEY (vehicle_id)  REFERENCES Vehicle(vehicle_id)
);

CREATE TABLE Booking (
  booking_id         INT PRIMARY KEY AUTO_INCREMENT,
  cust_id            INT NOT NULL,
  service_id         INT NOT NULL,
  origin_branch_id   INT NOT NULL,
  dest_city          VARCHAR(40) NOT NULL,
  booking_date       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expected_delivery  DATE NOT NULL,
  FOREIGN KEY (cust_id)          REFERENCES Customer(cust_id),
  FOREIGN KEY (service_id)       REFERENCES ServiceType(service_id),
  FOREIGN KEY (origin_branch_id) REFERENCES Branch(branch_id)
);

CREATE TABLE Parcel (
  parcel_id    INT PRIMARY KEY AUTO_INCREMENT,
  booking_id   INT NOT NULL,
  tracking_no  VARCHAR(20) NOT NULL UNIQUE,
  weight_kg    DECIMAL(6,2) NOT NULL CHECK (weight_kg > 0),
  description  VARCHAR(60),
  status       ENUM('BOOKED','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED','FAILED')
               NOT NULL DEFAULT 'BOOKED',
  route_id     INT,
  agent_id     INT,
  FOREIGN KEY (booking_id) REFERENCES Booking(booking_id),
  FOREIGN KEY (route_id)   REFERENCES Route(route_id),
  FOREIGN KEY (agent_id)   REFERENCES DeliveryAgent(agent_id)
);

CREATE TABLE ScanEvent (
  scan_id    INT PRIMARY KEY AUTO_INCREMENT,
  parcel_id  INT NOT NULL,
  seq_no     INT NOT NULL CHECK (seq_no > 0),
  branch_id  INT,
  hub_id     INT,
  scan_type  ENUM('BOOKED','PICKED_UP','AT_HUB','OUT_FOR_DELIVERY','DELIVERED','FAILED_ATTEMPT') NOT NULL,
  scan_time  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (parcel_id, seq_no),
  CHECK (branch_id IS NOT NULL OR hub_id IS NOT NULL),
  FOREIGN KEY (parcel_id) REFERENCES Parcel(parcel_id),
  FOREIGN KEY (branch_id) REFERENCES Branch(branch_id),
  FOREIGN KEY (hub_id)    REFERENCES Hub(hub_id)
);

CREATE TABLE DeliveryAttempt (
  attempt_id    INT PRIMARY KEY AUTO_INCREMENT,
  parcel_id     INT NOT NULL,
  agent_id      INT NOT NULL,
  attempt_no    INT NOT NULL CHECK (attempt_no BETWEEN 1 AND 3),
  attempt_time  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  result        ENUM('SUCCESS','FAILED') NOT NULL,
  reason        VARCHAR(80),
  UNIQUE (parcel_id, attempt_no),
  FOREIGN KEY (parcel_id) REFERENCES Parcel(parcel_id),
  FOREIGN KEY (agent_id)  REFERENCES DeliveryAgent(agent_id)
);

CREATE TABLE Charge (
  charge_id    INT PRIMARY KEY AUTO_INCREMENT,
  booking_id   INT NOT NULL,
  description  VARCHAR(40) NOT NULL,
  amount       DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  FOREIGN KEY (booking_id) REFERENCES Booking(booking_id)
);

CREATE TABLE Payment (
  payment_id    INT PRIMARY KEY AUTO_INCREMENT,
  booking_id    INT NOT NULL,
  amount        DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  method        ENUM('CASH','UPI','CARD') NOT NULL DEFAULT 'CASH',
  payment_date  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (booking_id) REFERENCES Booking(booking_id)
);

SHOW TABLES;


-- ---------------------------------------------------------------------
-- STEP 3: Indexes for frequently searched columns
-- (tracking_no is already indexed because it is UNIQUE)
-- ---------------------------------------------------------------------
CREATE INDEX idx_parcel_status  ON Parcel(status);
CREATE INDEX idx_scan_time      ON ScanEvent(scan_time);
CREATE INDEX idx_booking_cust   ON Booking(cust_id);


-- ---------------------------------------------------------------------
-- STEP 4: Triggers (valid scan sequence, no scan after delivery,
--         payment limit, auto status update)
-- Paste each trigger fully, including the DELIMITER lines.
-- ---------------------------------------------------------------------
DELIMITER $$

CREATE TRIGGER trg_scan_before_insert
BEFORE INSERT ON ScanEvent
FOR EACH ROW
BEGIN
  DECLARE cur_status VARCHAR(20);
  DECLARE last_seq INT;

  SELECT status INTO cur_status FROM Parcel WHERE parcel_id = NEW.parcel_id;
  IF cur_status = 'DELIVERED' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No scans allowed after delivery';
  END IF;

  SELECT IFNULL(MAX(seq_no), 0) INTO last_seq FROM ScanEvent WHERE parcel_id = NEW.parcel_id;
  IF NEW.seq_no <> last_seq + 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid scan sequence';
  END IF;
END$$

CREATE TRIGGER trg_scan_after_insert
AFTER INSERT ON ScanEvent
FOR EACH ROW
BEGIN
  UPDATE Parcel
  SET status = CASE NEW.scan_type
      WHEN 'BOOKED'           THEN 'BOOKED'
      WHEN 'PICKED_UP'        THEN 'IN_TRANSIT'
      WHEN 'AT_HUB'           THEN 'IN_TRANSIT'
      WHEN 'OUT_FOR_DELIVERY' THEN 'OUT_FOR_DELIVERY'
      WHEN 'DELIVERED'        THEN 'DELIVERED'
      ELSE 'FAILED' END
  WHERE parcel_id = NEW.parcel_id;
END$$

CREATE TRIGGER trg_payment_before_insert
BEFORE INSERT ON Payment
FOR EACH ROW
BEGIN
  DECLARE total_charge DECIMAL(10,2);
  DECLARE total_paid   DECIMAL(10,2);

  SELECT IFNULL(SUM(amount), 0) INTO total_charge FROM Charge  WHERE booking_id = NEW.booking_id;
  SELECT IFNULL(SUM(amount), 0) INTO total_paid   FROM Payment WHERE booking_id = NEW.booking_id;

  IF total_paid + NEW.amount > total_charge THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds total charge';
  END IF;
END$$

DELIMITER ;


-- ---------------------------------------------------------------------
-- STEP 5: Insert sample data (paste in this order)
-- ---------------------------------------------------------------------
INSERT INTO Customer (cust_id, cust_name, phone, email, address) VALUES
(1,'Ramesh Kumar','9000000001','ramesh@mail.com','Miryalaguda'),
(2,'Sneha Reddy','9000000002','sneha@mail.com','Miryalaguda'),
(3,'Arjun Rao','9000000003','arjun@mail.com','Hyderabad'),
(4,'Priya Sharma','9000000004','priya@mail.com','Hyderabad'),
(5,'Kiran Babu','9000000005','kiran@mail.com','Vijayawada');

INSERT INTO Branch (branch_id, branch_name, city) VALUES
(1,'Miryalaguda Branch','Miryalaguda'),
(2,'Hyderabad Central','Hyderabad'),
(3,'Vijayawada Branch','Vijayawada');

INSERT INTO Hub (hub_id, hub_name, city) VALUES
(1,'Hyderabad Hub','Hyderabad'),
(2,'Vijayawada Hub','Vijayawada'),
(3,'Chennai Hub','Chennai');

INSERT INTO ServiceType (service_id, service_name, base_charge, per_kg_charge, max_days) VALUES
(1,'Standard',40,10,5),
(2,'Express',80,20,2),
(3,'Same Day',150,35,1);

INSERT INTO DeliveryAgent (agent_id, agent_name, phone, branch_id) VALUES
(1,'Ravi Kumar','9876500001',1),
(2,'Suresh Reddy','9876500002',3),
(3,'Anil Varma','9876500003',2);

INSERT INTO Vehicle (vehicle_id, reg_no, vehicle_type, capacity_kg) VALUES
(1,'TS07AB1234','Truck',2000),
(2,'AP16CD5678','Van',800),
(3,'TS09EF9012','Van',600);

INSERT INTO Route (route_id, route_name, from_hub_id, to_hub_id, distance_km, vehicle_id) VALUES
(1,'Hyderabad-Vijayawada',1,2,275,1),
(2,'Vijayawada-Chennai',2,3,450,2),
(3,'Hyderabad-Chennai',1,3,630,3);

INSERT INTO Booking (booking_id, cust_id, service_id, origin_branch_id, dest_city, booking_date, expected_delivery) VALUES
(1,1,1,1,'Hyderabad','2026-10-01 10:00:00','2026-10-06'),
(2,2,2,1,'Vijayawada','2026-10-02 11:30:00','2026-10-04'),
(3,3,1,2,'Chennai','2026-10-03 09:15:00','2026-10-08'),
(4,4,3,2,'Hyderabad','2026-10-05 14:00:00','2026-10-05'),
(5,5,1,3,'Hyderabad','2026-10-06 16:45:00','2026-12-31'),
(6,1,2,1,'Chennai','2026-10-07 12:00:00','2026-12-31');

INSERT INTO Parcel (parcel_id, booking_id, tracking_no, weight_kg, description, route_id, agent_id) VALUES
(1,1,'TRK1001',2.50,'Documents',1,1),
(2,2,'TRK1002',5.00,'Books',1,2),
(3,3,'TRK1003',10.00,'Electronics',3,3),
(4,4,'TRK1004',1.20,'Gift',1,3),
(5,5,'TRK1005',7.50,'Clothes',1,2),
(6,6,'TRK1006',3.00,'Medicines',3,1);

INSERT INTO Charge (booking_id, description, amount) VALUES
(1,'Base charge',40),(1,'Weight charge',25),
(2,'Base charge',80),(2,'Weight charge',100),
(3,'Base charge',40),(3,'Weight charge',100),
(4,'Base charge',150),(4,'Weight charge',42),
(5,'Base charge',40),(5,'Weight charge',75),
(6,'Base charge',80),(6,'Weight charge',60);

-- Scan events (one INSERT per parcel; status updates automatically by trigger)
INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type, scan_time) VALUES
(1,1,1,NULL,'BOOKED','2026-10-01 10:05:00'),
(1,2,1,NULL,'PICKED_UP','2026-10-01 16:00:00'),
(1,3,NULL,1,'AT_HUB','2026-10-02 09:00:00'),
(1,4,2,NULL,'OUT_FOR_DELIVERY','2026-10-05 09:00:00'),
(1,5,2,NULL,'DELIVERED','2026-10-05 12:30:00');

INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type, scan_time) VALUES
(2,1,1,NULL,'BOOKED','2026-10-02 11:40:00'),
(2,2,1,NULL,'PICKED_UP','2026-10-02 17:00:00'),
(2,3,NULL,1,'AT_HUB','2026-10-03 08:00:00'),
(2,4,NULL,2,'AT_HUB','2026-10-03 20:00:00'),
(2,5,3,NULL,'OUT_FOR_DELIVERY','2026-10-06 09:00:00'),
(2,6,3,NULL,'FAILED_ATTEMPT','2026-10-06 14:00:00');

INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type, scan_time) VALUES
(3,1,2,NULL,'BOOKED','2026-10-03 09:20:00'),
(3,2,2,NULL,'PICKED_UP','2026-10-03 15:00:00'),
(3,3,NULL,1,'AT_HUB','2026-10-04 07:00:00'),
(3,4,NULL,3,'AT_HUB','2026-10-05 22:00:00');

INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type, scan_time) VALUES
(4,1,2,NULL,'BOOKED','2026-10-05 14:05:00'),
(4,2,2,NULL,'PICKED_UP','2026-10-05 14:30:00'),
(4,3,2,NULL,'OUT_FOR_DELIVERY','2026-10-05 15:00:00'),
(4,4,2,NULL,'DELIVERED','2026-10-05 16:20:00');

INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type, scan_time) VALUES
(5,1,3,NULL,'BOOKED','2026-10-06 16:50:00'),
(5,2,3,NULL,'PICKED_UP','2026-10-07 09:00:00'),
(5,3,NULL,2,'AT_HUB','2026-10-07 20:00:00');

INSERT INTO ScanEvent (parcel_id, seq_no, branch_id, hub_id, scan_type, scan_time) VALUES
(6,1,1,NULL,'BOOKED','2026-10-07 12:10:00');

INSERT INTO DeliveryAttempt (parcel_id, agent_id, attempt_no, attempt_time, result, reason) VALUES
(1,1,1,'2026-10-05 12:30:00','SUCCESS',NULL),
(2,2,1,'2026-10-06 14:00:00','FAILED','Customer not available'),
(4,3,1,'2026-10-05 16:20:00','SUCCESS',NULL);

INSERT INTO Payment (booking_id, amount, method, payment_date) VALUES
(1,65,'CASH','2026-10-01 10:10:00'),
(2,100,'UPI','2026-10-02 11:45:00'),
(3,140,'CARD','2026-10-03 09:20:00'),
(4,192,'UPI','2026-10-05 14:10:00'),
(6,70,'CASH','2026-10-07 12:15:00');


-- ---------------------------------------------------------------------
-- STEP 6: Check the data
-- ---------------------------------------------------------------------
SELECT * FROM Customer;
SELECT * FROM Parcel;
SELECT * FROM ScanEvent ORDER BY parcel_id, seq_no;
DESCRIBE Parcel;


-- ---------------------------------------------------------------------
-- STEP 7: Basic retrieval, joins, charge calculation
-- ---------------------------------------------------------------------
-- Track a parcel by tracking number
SELECT p.tracking_no, p.status, c.cust_name, b.dest_city, b.expected_delivery
FROM Parcel p
JOIN Booking b ON b.booking_id = p.booking_id
JOIN Customer c ON c.cust_id = b.cust_id
WHERE p.tracking_no = 'TRK1002';

-- Full scan history of a parcel
SELECT p.tracking_no, s.seq_no, s.scan_type,
       COALESCE(br.branch_name, h.hub_name) AS location, s.scan_time
FROM ScanEvent s
JOIN Parcel p ON p.parcel_id = s.parcel_id
LEFT JOIN Branch br ON br.branch_id = s.branch_id
LEFT JOIN Hub h ON h.hub_id = s.hub_id
WHERE p.tracking_no = 'TRK1002'
ORDER BY s.seq_no;

-- Charge calculation = base charge + per-kg charge x weight
SELECT p.tracking_no, p.weight_kg, st.service_name,
       st.base_charge + st.per_kg_charge * p.weight_kg AS calculated_charge
FROM Parcel p
JOIN Booking b ON b.booking_id = p.booking_id
JOIN ServiceType st ON st.service_id = b.service_id;


-- ---------------------------------------------------------------------
-- STEP 8: Aggregate functions and nested queries
-- ---------------------------------------------------------------------
-- Parcels per status
SELECT status, COUNT(*) AS total_parcels FROM Parcel GROUP BY status;

-- Average, maximum weight
SELECT ROUND(AVG(weight_kg),2) AS avg_weight, MAX(weight_kg) AS max_weight FROM Parcel;

-- Parcels heavier than average (nested query)
SELECT tracking_no, weight_kg FROM Parcel
WHERE weight_kg > (SELECT AVG(weight_kg) FROM Parcel);

-- Customers who have at least one failed parcel (nested query)
SELECT cust_name FROM Customer
WHERE cust_id IN (
  SELECT b.cust_id FROM Booking b
  JOIN Parcel p ON p.booking_id = b.booking_id
  WHERE p.status = 'FAILED');

-- Bookings that are not fully paid (nested query)
SELECT b.booking_id,
       (SELECT SUM(amount) FROM Charge  WHERE booking_id = b.booking_id) AS billed,
       IFNULL((SELECT SUM(amount) FROM Payment WHERE booking_id = b.booking_id),0) AS paid
FROM Booking b
HAVING billed > paid;


-- ---------------------------------------------------------------------
-- STEP 9: Views (reports)
-- ---------------------------------------------------------------------
-- Current parcel location
CREATE VIEW v_current_location AS
SELECT p.tracking_no, p.status, s.scan_type,
       COALESCE(br.branch_name, h.hub_name) AS location, s.scan_time
FROM Parcel p
JOIN ScanEvent s ON s.parcel_id = p.parcel_id
LEFT JOIN Branch br ON br.branch_id = s.branch_id
LEFT JOIN Hub h ON h.hub_id = s.hub_id
WHERE s.seq_no = (SELECT MAX(seq_no) FROM ScanEvent WHERE parcel_id = p.parcel_id);

-- Delayed shipments
CREATE VIEW v_delayed_shipments AS
SELECT p.tracking_no, p.status, b.expected_delivery,
       DATEDIFF(CURDATE(), b.expected_delivery) AS days_late
FROM Parcel p
JOIN Booking b ON b.booking_id = p.booking_id
WHERE p.status <> 'DELIVERED' AND b.expected_delivery < CURDATE();

-- Branch load
CREATE VIEW v_branch_load AS
SELECT br.branch_name, COUNT(p.parcel_id) AS parcels_booked
FROM Branch br
LEFT JOIN Booking bk ON bk.origin_branch_id = br.branch_id
LEFT JOIN Parcel p ON p.booking_id = bk.booking_id
GROUP BY br.branch_id, br.branch_name;

-- Route performance (average hours from booking to delivery)
CREATE VIEW v_route_performance AS
SELECT r.route_name, COUNT(p.parcel_id) AS parcels,
       ROUND(AVG(TIMESTAMPDIFF(HOUR, bk.booking_date, d.scan_time)),1) AS avg_hours_to_deliver
FROM Route r
JOIN Parcel p ON p.route_id = r.route_id
JOIN Booking bk ON bk.booking_id = p.booking_id
LEFT JOIN ScanEvent d ON d.parcel_id = p.parcel_id AND d.scan_type = 'DELIVERED'
GROUP BY r.route_id, r.route_name;

-- Failed attempts per agent
CREATE VIEW v_failed_attempts AS
SELECT a.agent_name, COUNT(*) AS failed_attempts
FROM DeliveryAttempt da
JOIN DeliveryAgent a ON a.agent_id = da.agent_id
WHERE da.result = 'FAILED'
GROUP BY a.agent_id, a.agent_name;

-- Revenue by service type
CREATE VIEW v_revenue AS
SELECT st.service_name,
  (SELECT IFNULL(SUM(c.amount),0) FROM Charge c
     JOIN Booking b2 ON b2.booking_id = c.booking_id
     WHERE b2.service_id = st.service_id) AS billed,
  (SELECT IFNULL(SUM(pm.amount),0) FROM Payment pm
     JOIN Booking b3 ON b3.booking_id = pm.booking_id
     WHERE b3.service_id = st.service_id) AS collected
FROM ServiceType st;


-- ---------------------------------------------------------------------
-- STEP 10: Run the reports
-- ---------------------------------------------------------------------
SELECT * FROM v_current_location;
SELECT * FROM v_delayed_shipments;
SELECT * FROM v_branch_load;
SELECT * FROM v_route_performance;
SELECT * FROM v_failed_attempts;
SELECT * FROM v_revenue;


