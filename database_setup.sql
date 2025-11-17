-- CREATING OUR DATABASE 'ExpenseTracker'
CREATE DATABASE IF NOT EXISTS ExpenseTracker;
USE ExpenseTracker;

-- CREATING TABLES

-- Table: Users
CREATE TABLE Users(
    uid INT AUTO_INCREMENT PRIMARY KEY,
    uname VARCHAR(100) NOT NULL,
    email VARCHAR(150) UNIQUE NOT NULL,
    password VARCHAR(100) NOT NULL,
    CHECK (CHAR_LENGTH(password) >= 6)
);

-- Table: ExpenseGroups (removed total_balance column)
CREATE TABLE ExpenseGroups (
    grp_id INT AUTO_INCREMENT PRIMARY KEY,
    grp_name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    created_by INT DEFAULT NULL,
    CONSTRAINT fk_groups_created_by FOREIGN KEY (created_by)
        REFERENCES Users(uid)
        ON DELETE SET NULL
        ON UPDATE CASCADE
);

-- Table: Group_Members
CREATE TABLE Group_Members(
    grp_id INT NOT NULL,
    uid INT NOT NULL,
    joined_at DATE NOT NULL DEFAULT (CURRENT_DATE),
    PRIMARY KEY (grp_id, uid),
    FOREIGN KEY (grp_id) REFERENCES ExpenseGroups(grp_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    FOREIGN KEY (uid) REFERENCES Users(uid)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

-- Table: Expenses
CREATE TABLE Expenses(
    eid INT AUTO_INCREMENT PRIMARY KEY,
    grp_id INT NOT NULL,
    paidby_user INT DEFAULT NULL,
    amount DECIMAL(10,2) NOT NULL,
    expense_date DATE NOT NULL,
    expense_time TIME NOT NULL,
    description VARCHAR(255),
    FOREIGN KEY (grp_id) REFERENCES ExpenseGroups(grp_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    FOREIGN KEY (paidby_user) REFERENCES Users(uid)
        ON DELETE SET NULL
        ON UPDATE CASCADE,
    CHECK (amount > 0)
);

-- Table: Expense_Splits (tracks each person's share of each expense)
CREATE TABLE Expense_Splits(
    eid INT NOT NULL,
    uid INT NOT NULL,
    share_amount DECIMAL(10,2) NOT NULL,
    settled BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (eid, uid),
    FOREIGN KEY (eid) REFERENCES Expenses(eid)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    FOREIGN KEY (uid) REFERENCES Users(uid)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CHECK (share_amount >= 0)
);

-- Table: Settlements (tracks payments between users)
CREATE TABLE Settlements(
	sid INT AUTO_INCREMENT PRIMARY KEY,
	payer_uid INT NOT NULL,
	payee_uid INT NOT NULL,
	grp_id INT NOT NULL,
	amount DECIMAL(10,2) NOT NULL,
	status VARCHAR(50) NOT NULL DEFAULT 'Pending',
	settlement_date DATE NOT NULL DEFAULT (CURRENT_DATE),
	FOREIGN KEY (payer_uid) REFERENCES Users(uid)
		ON DELETE CASCADE
		ON UPDATE CASCADE,
	FOREIGN KEY (payee_uid) REFERENCES Users(uid)
		ON DELETE CASCADE
		ON UPDATE CASCADE,
	FOREIGN KEY (grp_id) REFERENCES ExpenseGroups(grp_id)
		ON DELETE CASCADE
		ON UPDATE CASCADE,
	CHECK (amount > 0)
);

-- CREATE INDEXES FOR BETTER PERFORMANCE
CREATE INDEX idx_expenses_grp ON Expenses(grp_id);
CREATE INDEX idx_expenses_paidby ON Expenses(paidby_user);
CREATE INDEX idx_expense_splits_uid ON Expense_Splits(uid);
CREATE INDEX idx_settlements_payer ON Settlements(payer_uid);
CREATE INDEX idx_settlements_payee ON Settlements(payee_uid);
CREATE INDEX idx_settlements_grp ON Settlements(grp_id);
CREATE INDEX idx_group_members_uid ON Group_Members(uid);

-- INSERTING SAMPLE DATA
INSERT INTO Users (uname, email, password) VALUES
('Lakshitha', 'lakshitha@gmail.com', '1234abc'),
('Unnathi', 'unnathi@gmail.com', 'xyz5678'),
('John', 'john@gmail.com', '1a1b1c1'),
('Amanda', 'amanda@yahoo.com', '44eeee44'),
('Sara', 'sara@outlook.com', 'sararaa');

INSERT INTO ExpenseGroups (grp_name, description, created_by) VALUES
('Lunch', 'NA', 1),
('Travel', 'auto', 2),
('Dinner', 'birthdayy', 3),
('AppleMusic', 'Apple music subscription', 4),
('Movie', 'movie tickets', 5);

INSERT INTO Group_Members (grp_id, uid, joined_at) VALUES
(1, 1, '2025-09-01'),
(1, 2, '2025-09-01'),
(1, 3, '2025-09-02'),
(2, 2, '2025-09-05'),
(2, 5, '2025-09-05'),
(3, 3, '2025-09-07'),
(3, 4, '2025-09-07');

-- STORED PROCEDURES

DELIMITER //

-- Procedure 1: Add expense and split equally among group members
CREATE PROCEDURE AddExpenseWithSplits(
    IN p_grp_id INT,
    IN p_paid_by INT,
    IN p_amount DECIMAL(10,2),
    IN p_expense_date DATE,
    IN p_description VARCHAR(255)
)
BEGIN
    DECLARE v_member_count INT;
    DECLARE v_share_amount DECIMAL(10,2);
    DECLARE v_eid INT;
    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Verify the payer is a member of the group
    IF NOT EXISTS (SELECT 1 FROM Group_Members WHERE grp_id = p_grp_id AND uid = p_paid_by) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Payer must be a member of the group';
    END IF;

    -- Insert the expense
    INSERT INTO Expenses (grp_id, paidby_user, amount, expense_date, expense_time, description)
    VALUES (p_grp_id, p_paid_by, p_amount, p_expense_date, CURTIME(), p_description);

    SET v_eid = LAST_INSERT_ID();

    -- Calculate equal share
    SELECT COUNT(*) INTO v_member_count FROM Group_Members WHERE grp_id = p_grp_id;
    
    IF v_member_count = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Group has no members';
    END IF;
    
    SET v_share_amount = p_amount / v_member_count;

    -- Insert splits for each member
    INSERT INTO Expense_Splits (eid, uid, share_amount)
    SELECT v_eid, uid, v_share_amount
    FROM Group_Members
    WHERE grp_id = p_grp_id;

    COMMIT;
    
    SELECT CONCAT('Expense added successfully. Expense ID: ', v_eid, '. Each person owes: ', ROUND(v_share_amount, 2)) AS result;
END //

-- Procedure 2: Get simplified settlements for a group (who owes whom)
CREATE PROCEDURE GetGroupSettlements(IN p_grp_id INT)
BEGIN
    -- Create temporary table for net balances
    DROP TEMPORARY TABLE IF EXISTS temp_balances;
    CREATE TEMPORARY TABLE temp_balances (
        uid INT,
        uname VARCHAR(100),
        net_balance DECIMAL(10,2)
    );
    
    -- Calculate net balance for each member
    -- Net balance = Total paid - Total owed
    -- Positive = they should receive money
    -- Negative = they should pay money
    INSERT INTO temp_balances
    SELECT 
        u.uid,
        u.uname,
        IFNULL(paid.total_paid, 0) - IFNULL(owed.total_owed, 0) AS net_balance
    FROM Users u
    JOIN Group_Members gm ON u.uid = gm.uid
    LEFT JOIN (
        SELECT paidby_user, SUM(amount) as total_paid
        FROM Expenses
        WHERE grp_id = p_grp_id
        GROUP BY paidby_user
    ) paid ON u.uid = paid.paidby_user
    LEFT JOIN (
        SELECT es.uid, SUM(es.share_amount) as total_owed
        FROM Expense_Splits es
        JOIN Expenses e ON es.eid = e.eid
        WHERE e.grp_id = p_grp_id
        GROUP BY es.uid
    ) owed ON u.uid = owed.uid
    WHERE gm.grp_id = p_grp_id;
    
    -- Show individual balances
    SELECT 
        uid,
        uname,
        ROUND(net_balance, 2) AS net_balance,
        CASE 
            WHEN net_balance > 0 THEN CONCAT('Should receive ₹', ROUND(net_balance, 2))
            WHEN net_balance < 0 THEN CONCAT('Should pay ₹', ROUND(ABS(net_balance), 2))
            ELSE 'Settled'
        END AS status
    FROM temp_balances
    ORDER BY net_balance DESC;
    
    DROP TEMPORARY TABLE temp_balances;
END //

-- Procedure 3: Get detailed settlement transactions (who pays whom how much)
DELIMITER //

CREATE PROCEDURE GetDetailedSettlements(IN p_grp_id INT)
BEGIN
    -- Use a derived table for balances
    SELECT 
        debtor.debtor_name,
        creditor.creditor_name,
        ROUND(LEAST(ABS(debtor.net_balance), creditor.net_balance), 2) AS amount_to_pay
    FROM 
        (SELECT u.uid, u.uname AS debtor_name, 
                IFNULL(paid.total_paid, 0) - IFNULL(owed.total_owed, 0) AS net_balance
         FROM Users u
         JOIN Group_Members gm ON u.uid = gm.uid
         LEFT JOIN (
             SELECT paidby_user, SUM(amount) AS total_paid
             FROM Expenses
             WHERE grp_id = p_grp_id
             GROUP BY paidby_user
         ) paid ON u.uid = paid.paidby_user
         LEFT JOIN (
             SELECT es.uid, SUM(es.share_amount) AS total_owed
             FROM Expense_Splits es
             JOIN Expenses e ON es.eid = e.eid
             WHERE e.grp_id = p_grp_id
             GROUP BY es.uid
         ) owed ON u.uid = owed.uid
         WHERE gm.grp_id = p_grp_id
         HAVING net_balance < -0.01
        ) debtor
    CROSS JOIN 
        (SELECT u.uid, u.uname AS creditor_name, 
                IFNULL(paid.total_paid, 0) - IFNULL(owed.total_owed, 0) AS net_balance
         FROM Users u
         JOIN Group_Members gm ON u.uid = gm.uid
         LEFT JOIN (
             SELECT paidby_user, SUM(amount) AS total_paid
             FROM Expenses
             WHERE grp_id = p_grp_id
             GROUP BY paidby_user
         ) paid ON u.uid = paid.paidby_user
         LEFT JOIN (
             SELECT es.uid, SUM(es.share_amount) AS total_owed
             FROM Expense_Splits es
             JOIN Expenses e ON es.eid = e.eid
             WHERE e.grp_id = p_grp_id
             GROUP BY es.uid
         ) owed ON u.uid = owed.uid
         WHERE gm.grp_id = p_grp_id
         HAVING net_balance > 0.01
        ) creditor
    ORDER BY amount_to_pay DESC;
END //


-- Procedure 4: Record a settlement between two users
CREATE PROCEDURE RecordSettlement(
    IN p_payer_uid INT,
    IN p_payee_uid INT,
    IN p_grp_id INT,
    IN p_amount DECIMAL(10,2)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    
    -- Verify both users are in the group
    IF NOT EXISTS (SELECT 1 FROM Group_Members WHERE grp_id = p_grp_id AND uid = p_payer_uid) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Payer is not a member of the group';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM Group_Members WHERE grp_id = p_grp_id AND uid = p_payee_uid) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Payee is not a member of the group';
    END IF;

    -- Insert settlement record
    INSERT INTO Settlements (payer_uid, payee_uid, grp_id, amount, status, settlement_date)
    VALUES (p_payer_uid, p_payee_uid, p_grp_id, p_amount, 'Completed', CURDATE());

    -- Mark relevant expense splits as settled
    UPDATE Expense_Splits es
    JOIN Expenses e ON es.eid = e.eid
    SET es.settled = TRUE
    WHERE e.grp_id = p_grp_id
      AND es.uid = p_payer_uid
      AND e.paidby_user = p_payee_uid
      AND es.settled = FALSE;

    COMMIT;
    
    SELECT CONCAT('Settlement of ₹', p_amount, ' recorded from ', 
                  (SELECT uname FROM Users WHERE uid = p_payer_uid), ' to ',
                  (SELECT uname FROM Users WHERE uid = p_payee_uid)) AS result;
END //

DELIMITER ;

-- FUNCTIONS

DELIMITER //

-- Function 1: Returns total paid by a user across all groups
CREATE FUNCTION GetTotalExpensesByUser(p_uid INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
DETERMINISTIC
BEGIN
    DECLARE total DECIMAL(10,2);
    SELECT IFNULL(SUM(amount), 0) INTO total
    FROM Expenses
    WHERE paidby_user = p_uid;
    RETURN total;
END //

-- Function 2: Calculate net balance for a user in a specific group
-- Positive = they should receive, Negative = they should pay
CREATE FUNCTION GetUserBalance(p_uid INT, p_grp_id INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
DETERMINISTIC
BEGIN
    DECLARE v_paid DECIMAL(10,2);
    DECLARE v_owed DECIMAL(10,2);
    
    -- Total paid by user
    SELECT IFNULL(SUM(amount), 0) INTO v_paid
    FROM Expenses
    WHERE paidby_user = p_uid AND grp_id = p_grp_id;
    
    -- Total owed by user (their share of all expenses)
    SELECT IFNULL(SUM(es.share_amount), 0) INTO v_owed
    FROM Expense_Splits es
    JOIN Expenses e ON es.eid = e.eid
    WHERE es.uid = p_uid AND e.grp_id = p_grp_id;
    
    RETURN v_paid - v_owed;
END //

-- Function 3: Get total group expenses
CREATE FUNCTION GetGroupTotalExpenses(p_grp_id INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
DETERMINISTIC
BEGIN
    DECLARE total DECIMAL(10,2);
    SELECT IFNULL(SUM(amount), 0) INTO total
    FROM Expenses
    WHERE grp_id = p_grp_id;
    RETURN total;
END //

DELIMITER ;


-- TRIGGERS

-- Trigger 1: Auto-Update Expense Split Settlement Status
DELIMITER //

CREATE TRIGGER after_settlement_insert
AFTER INSERT ON Settlements
FOR EACH ROW
BEGIN
    -- Mark relevant expense splits as settled when a settlement is recorded
    UPDATE Expense_Splits es
    JOIN Expenses e ON es.eid = e.eid
    SET es.settled = TRUE
    WHERE e.grp_id = NEW.grp_id
      AND es.uid = NEW.payer_uid
      AND e.paidby_user = NEW.payee_uid
      AND es.settled = FALSE
      AND NEW.status = 'Completed';
END //

DELIMITER ;



-- View all pending and completed transactions
CREATE VIEW AllSettlements AS
-- Pending settlements (calculated from net balances)
SELECT 
    NULL AS settlement_id,
    debtor.uid AS payer_uid,
    debtor.uname AS payer_name,
    creditor.uid AS payee_uid,
    creditor.uname AS payee_name,
    eg.grp_id,
    eg.grp_name,
    ROUND(LEAST(ABS(debtor.net_balance), creditor.net_balance), 2) AS amount,
    'Pending' AS status,
    NULL AS settlement_date
FROM ExpenseGroups eg
JOIN (
    SELECT 
        u.uid,
        u.uname,
        gm.grp_id,
        IFNULL(paid.total_paid, 0) - IFNULL(owed.total_owed, 0) AS net_balance
    FROM Users u
    JOIN Group_Members gm ON u.uid = gm.uid
    LEFT JOIN (
        SELECT paidby_user, grp_id, SUM(amount) as total_paid
        FROM Expenses
        GROUP BY paidby_user, grp_id
    ) paid ON u.uid = paid.paidby_user AND gm.grp_id = paid.grp_id
    LEFT JOIN (
        SELECT es.uid, e.grp_id, SUM(es.share_amount) as total_owed
        FROM Expense_Splits es
        JOIN Expenses e ON es.eid = e.eid
        WHERE es.settled = FALSE
        GROUP BY es.uid, e.grp_id
    ) owed ON u.uid = owed.uid AND gm.grp_id = owed.grp_id
    HAVING net_balance < -0.01
) debtor ON eg.grp_id = debtor.grp_id
JOIN (
    SELECT 
        u.uid,
        u.uname,
        gm.grp_id,
        IFNULL(paid.total_paid, 0) - IFNULL(owed.total_owed, 0) AS net_balance
    FROM Users u
    JOIN Group_Members gm ON u.uid = gm.uid
    LEFT JOIN (
        SELECT paidby_user, grp_id, SUM(amount) as total_paid
        FROM Expenses
        GROUP BY paidby_user, grp_id
    ) paid ON u.uid = paid.paidby_user AND gm.grp_id = paid.grp_id
    LEFT JOIN (
        SELECT es.uid, e.grp_id, SUM(es.share_amount) as total_owed
        FROM Expense_Splits es
        JOIN Expenses e ON es.eid = e.eid
        WHERE es.settled = FALSE
        GROUP BY es.uid, e.grp_id
    ) owed ON u.uid = owed.uid AND gm.grp_id = owed.grp_id
    HAVING net_balance > 0.01
) creditor ON eg.grp_id = creditor.grp_id

UNION ALL

-- Completed settlements (from Settlements table)
SELECT 
    s.sid AS settlement_id,
    s.payer_uid,
    u1.uname AS payer_name,
    s.payee_uid,
    u2.uname AS payee_name,
    s.grp_id,
    eg.grp_name,
    s.amount,
    s.status,
    s.settlement_date
FROM Settlements s
JOIN Users u1 ON s.payer_uid = u1.uid
JOIN Users u2 ON s.payee_uid = u2.uid
JOIN ExpenseGroups eg ON s.grp_id = eg.grp_id
ORDER BY grp_id, status, amount DESC;

-- view
SELECT * FROM AllSettlements;

-- NOW USE THE PROCEDURE TO ADD EXPENSES (instead of manual inserts)
-- This automatically creates the expense splits
-- Group 1 expenses (Lunch group)
CALL AddExpenseWithSplits(1, 1, 1500.00, '2025-09-01', 'Lunch payment by Lakshitha');
CALL AddExpenseWithSplits(1, 2, 100.00, '2025-09-02', 'Lunch payment by Unnathi');

-- Group 2 expenses (Travel group)
CALL AddExpenseWithSplits(2, 2, 10000.00, '2025-09-05', 'Auto ride');
CALL AddExpenseWithSplits(2, 5, 1000.00, '2025-09-06', 'Parking');

-- Group 3 expenses (Dinner group)
CALL AddExpenseWithSplits(3, 3, 1200.00, '2025-09-07', 'Birthday dinner');

-- VIEWING ALL TABLES
SELECT * FROM Users;
SELECT * FROM ExpenseGroups;
SELECT * FROM Group_Members;
SELECT * FROM Expenses;

SELECT 
    es.eid,
    e.description,
    u.uname,
    es.share_amount,
    es.settled
FROM Expense_Splits es
JOIN Expenses e ON es.eid = e.eid
JOIN Users u ON es.uid = u.uid
ORDER BY es.eid, u.uname;

-- VERIFICATION QUERIES

-- See net balances for Group 1 (Lunch)
CALL GetGroupSettlements(1);
-- See who owes whom in Group 1
CALL GetDetailedSettlements(1);

-- See balances for Group 2 (Travel)
CALL GetGroupSettlements(2);
CALL GetDetailedSettlements(2);

-- Settling an expense
CALL RecordSettlement(2, 1, 1, 433.33);

-- Total expenses paid by each user
SELECT 
    uid,
    uname,
    GetTotalExpensesByUser(uid) AS total_paid
FROM Users;