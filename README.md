# mysql-fix

Scripts for when XAMPP's MariaDB (MySQL) stops working on Windows.

Paths default to `C:\xampp`. Use `-Xampp D:\xampp` if yours is somewhere else.

## 1. MySQL won't start: `fix-mysql.bat`

This is the usual XAMPP fix ("rename data, copy backup"), done automatically:

1. Stops mysqld.
2. Renames `mysql\data` to `mysql\data_old_<timestamp>`. That folder is your full backup.
3. Copies `mysql\backup` (XAMPP's clean copy) to a new `mysql\data`.
4. Copies every database folder and `ibdata1` back from the old folder.
5. Starts MySQL and checks it is still up after 30 seconds.

If a copy fails, the original folder is put back.

```
fix-mysql.bat                 # double-click, or:
fix-mysql.bat -SkipDb klc     # leave a broken / half-imported database out
fix-mysql.bat -NoStart        # swap folders only
```

## 2. It runs, but the log says "log sequence number … is in the future": `rebuild-mysql.bat`

After the swap in step 1, the database files no longer match the InnoDB log files. MySQL runs, but large imports can crash it again. This script removes the mismatch for good. **MySQL must be running.**

1. Counts the rows of every table.
2. Dumps each database to `C:\xampp\mysql-dumps\<timestamp>\<db>.sql` and checks each dump finished.
3. Shuts MySQL down cleanly and renames `mysql\data` to `mysql\data_old_rebuild_<timestamp>`.
4. Creates a fresh `mysql\data` from `mysql\backup`, starts MySQL and imports every dump.
5. Counts the rows again and compares them with step 1.

If anything fails after step 3, it puts the original folder back and restarts MySQL.

```
rebuild-mysql.bat
rebuild-mysql.bat -SkipDb klc_test
```

## Notes

- `mysql`, `performance_schema`, `phpmyadmin` and `test` always come fresh from `mysql\backup`. MySQL users go back to the XAMPP defaults (root, no password).
- Each run writes a `*.log` next to the scripts.
- Delete the `data_old_*` folders and dumps once everything works.
- For big imports, raise these in `mysql\bin\my.ini`: `innodb_buffer_pool_size` (for example 1G), `innodb_log_file_size` (256M) and `innodb_log_buffer_size` (64M). Change them only after a clean shutdown.
