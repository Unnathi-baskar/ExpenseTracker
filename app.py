from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import mysql.connector
from mysql.connector import Error

app = Flask(__name__)
app.secret_key = 'expense_tracker_secret_key_2024'

# Database configuration
db_config = {
    'host': 'localhost',
    'user': 'root',
    'password': 'Unnu#666',
    'database': 'ExpenseTracker'
}

def get_db_connection():
    try:
        return mysql.connector.connect(**db_config)
    except Error as e:
        print(f"Error connecting to MySQL: {e}")
        return None


@app.route('/')
def index():
    return redirect(url_for('login'))


# ------------------- LOGIN & REGISTER -------------------

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        email = request.form['email']
        password = request.form['password']

        con = get_db_connection()
        cur = con.cursor(dictionary=True)
        cur.execute("SELECT * FROM Users WHERE email=%s AND password=%s", (email, password))
        user = cur.fetchone()
        cur.close()
        con.close()

        if user:
            session['user_id'] = user['uid']
            session['user_name'] = user['uname']
            return redirect(url_for('dashboard'))
        else:
            return render_template('login.html', error="Invalid credentials")
    return render_template('login.html')


@app.route('/register', methods=['GET', 'POST'])
def register():
    if request.method == 'POST':
        uname = request.form['uname']
        email = request.form['email']
        password = request.form['password']
        confirm_password = request.form['confirm_password']

        if password != confirm_password:
            return render_template('register.html', error="Passwords do not match")

        con = get_db_connection()
        cur = con.cursor(dictionary=True)
        cur.execute("SELECT * FROM Users WHERE email=%s", (email,))
        if cur.fetchone():
            return render_template('register.html', error="Email already exists")

        cur.execute("INSERT INTO Users (uname, email, password) VALUES (%s, %s, %s)", (uname, email, password))
        con.commit()
        cur.close()
        con.close()
        return redirect(url_for('login'))
    return render_template('register.html')


# ------------------- DASHBOARD -------------------

@app.route('/dashboard')
def dashboard():
    if 'user_id' not in session:
        return redirect(url_for('login'))

    uid = session['user_id']
    con = get_db_connection()
    cur = con.cursor(dictionary=True)
#Get user’s groups
    cur.execute("""
        SELECT eg.grp_id, eg.grp_name, eg.description
        FROM ExpenseGroups eg
        JOIN Group_Members gm ON eg.grp_id = gm.grp_id
        WHERE gm.uid = %s
    """, (uid,))
    groups = cur.fetchall()
#Get recent expenses
    cur.execute("""
        SELECT e.*, u.uname AS paid_by_name, eg.grp_name
        FROM Expenses e
        JOIN Users u ON e.paidby_user = u.uid
        JOIN ExpenseGroups eg ON e.grp_id = eg.grp_id
        WHERE e.grp_id IN (SELECT grp_id FROM Group_Members WHERE uid=%s)
        ORDER BY e.expense_date DESC, e.expense_time DESC
        LIMIT 5
    """, (uid,))
    recent_expenses = cur.fetchall()
#Get total owed amount
    cur.execute("""
        SELECT COALESCE(SUM(es.share_amount), 0) AS total_owed
        FROM Expense_Splits es
        JOIN Expenses e ON es.eid = e.eid
        WHERE es.uid=%s AND es.settled=FALSE
    """, (uid,))
    total_owed = cur.fetchone()['total_owed']

    cur.close()
    con.close()

    return render_template('dashboard.html',
                           user_name=session['user_name'],
                           groups=groups,
                           recent_expenses=recent_expenses,
                           total_owed=total_owed)


# ------------------- GROUP DETAILS -------------------

@app.route('/group/<int:group_id>')
def group_details(group_id):
    if 'user_id' not in session:
        return redirect(url_for('login'))

    con = get_db_connection()
    cur = con.cursor(dictionary=True)

    cur.execute("SELECT * FROM ExpenseGroups WHERE grp_id=%s", (group_id,))
    group = cur.fetchone()
# Get group members
    cur.execute("""
        SELECT u.uid, u.uname, u.email, gm.joined_at
        FROM Group_Members gm
        JOIN Users u ON gm.uid=u.uid
        WHERE gm.grp_id=%s
    """, (group_id,))
    members = cur.fetchall()
# Get group expenses
    cur.execute("""
        SELECT e.*, u.uname AS paid_by_name
        FROM Expenses e
        JOIN Users u ON e.paidby_user=u.uid
        WHERE e.grp_id=%s
        ORDER BY e.expense_date DESC, e.expense_time DESC
    """, (group_id,))
    expenses = cur.fetchall()
# Get expense splits
    for expense in expenses:
        cur.execute("""
            SELECT es.*, u.uname
            FROM Expense_Splits es
            JOIN Users u ON es.uid=u.uid
            WHERE es.eid=%s
        """, (expense['eid'],))
        expense['splits'] = cur.fetchall()

    cur.close()
    con.close()

    return render_template('group_details.html',
                           group=group,
                           members=members,
                           expenses=expenses)

@app.route('/get_group_members/<int:group_id>')
def get_group_members(group_id):
    con = get_db_connection()
    cur = con.cursor(dictionary=True)
    #get group members
    cur.execute("""
        SELECT u.uid, u.uname, u.email, gm.joined_at
        FROM Group_Members gm
        JOIN Users u ON gm.uid = u.uid
        WHERE gm.grp_id = %s
        ORDER BY u.uname
    """, (group_id,))
    members = cur.fetchall()
    cur.close()
    con.close()
    return jsonify({'success': True, 'members': members})

# ------------------- ADD EXPENSE -------------------

@app.route('/add_expense', methods=['POST'])
def add_expense():
    if 'user_id' not in session:
        return jsonify({'success': False, 'error': 'Not logged in'})

    data = request.get_json()
    grp_id = data['group_id']
    amount = float(data['amount'])
    description = data.get('description', '')
    splits = data.get('splits', {})

    if not splits:
        return jsonify({'success': False, 'error': 'No split members provided'})

    connection = get_db_connection()
    if not connection:
        return jsonify({'success': False, 'error': 'DB connection failed'})

    try:
        cursor = connection.cursor()
        cursor.execute("""
            INSERT INTO Expenses (grp_id, paidby_user, amount, expense_date, expense_time, description)
            VALUES (%s, %s, %s, CURRENT_DATE, CURRENT_TIME, %s)
        """, (grp_id, session['user_id'], amount, description))
        expense_id = cursor.lastrowid

        for uid, percentage in splits.items():
            share_amount = (amount * float(percentage)) / 100
            cursor.execute("""
                INSERT INTO Expense_Splits (eid, uid, share_amount, settled)
                VALUES (%s, %s, %s, FALSE)
            """, (expense_id, uid, share_amount))

        connection.commit()
        cursor.close()
        connection.close()
        return jsonify({'success': True})
    except Exception as e:
        print("Error adding expense:", e)
        return jsonify({'success': False, 'error': str(e)})



# ------------------- ADD GROUP MEMBER -------------------

@app.route('/add_group_member', methods=['POST'])
def add_group_member():
    if 'user_id' not in session:
        return jsonify({'success': False, 'error': 'Not logged in'})

    data = request.get_json()
    email = data['email']
    group_id = data['group_id']

    con = get_db_connection()
    cur = con.cursor(dictionary=True)
    cur.execute("SELECT uid FROM Users WHERE email=%s", (email,))
    user = cur.fetchone()
    if not user:
        return jsonify({'success': False, 'error': 'User not found'})

    cur.execute("INSERT IGNORE INTO Group_Members (grp_id, uid, joined_at) VALUES (%s, %s, CURRENT_DATE)", (group_id, user['uid']))
    con.commit()
    cur.close()
    con.close()
    return jsonify({'success': True})


# ------------------- SETTLEMENTS -------------------

@app.route('/get_group_settlements/<int:grp_id>')
def get_group_settlements(grp_id):
    connection = get_db_connection()
    cursor = connection.cursor(dictionary=True)
#This calculates each debtor-creditor pair’s outstanding amount.
    try:
        cursor.execute("""
            SELECT 
                debtor.uid AS debtor_uid,
                debtor.uname AS debtor_name,
                creditor.uid AS creditor_uid,
                creditor.uname AS creditor_name,
                ROUND(SUM(es.share_amount), 2) AS amount_to_pay
            FROM Expense_Splits es
            JOIN Expenses e ON es.eid = e.eid
            JOIN Users debtor ON es.uid = debtor.uid
            JOIN Users creditor ON e.paidby_user = creditor.uid
            WHERE e.grp_id = %s
              AND es.uid != e.paidby_user
              AND (es.settled = 0 OR es.settled IS NULL)
            GROUP BY debtor.uid, creditor.uid
            HAVING amount_to_pay > 0
        """, (grp_id,))

        settlements = cursor.fetchall()
        print(f"Fetched settlements for group {grp_id}: {settlements}")

        return jsonify({'success': True, 'settlements': settlements})
    except Exception as e:
        print(f"Error fetching settlements: {e}")
        return jsonify({'success': False, 'error': str(e)})
    finally:
        cursor.close()
        connection.close()


@app.route('/settle_debt', methods=['POST'])
def settle_debt():
    data = request.get_json()
    payer_uid = data['payer_uid']
    payee_uid = data['payee_uid']
    grp_id = data['grp_id']
    amount = data['amount']

    con = get_db_connection()
    cur = con.cursor()
    try:
        cur.callproc('RecordSettlement', [payer_uid, payee_uid, grp_id, amount])
        con.commit()
        cur.close()
        con.close()
        return jsonify({'success': True})
    except Exception as e:
        con.rollback()
        return jsonify({'success': False, 'error': str(e)})


# ------------------- LOGOUT -------------------

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


if __name__ == '__main__':
    app.run(debug=True)
