#!/bin/sh
# Ephemeral servers for the live database tests. "up" starts them and seeds the
# fixtures, "down" removes them. The data is deliberately awkward: commas,
# quotes, newlines, NULL next to the empty string, CJK, emoji, bytea, an int8
# past 2^53, and a numeric that must not be rounded.
set -e

PW='p@ss:w/rd#1'
MSSQL_PW='Str0ng:P/ss#1'

# Readiness is the seed itself succeeding. A port that accepts connections is
# not enough: the postgres image answers pg_isready while still initialising,
# and then restarts.
retry() {
    label=$1
    shift
    attempt=0
    until "$@" >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 90 ]; then
            echo "giving up on $label" >&2
            return 1
        fi
        [ $((attempt % 5)) -eq 0 ] && printf '.'
        sleep 2
    done
    echo " $label ready"
}

seed_postgres() {
    docker exec nvdb-pg psql -v ON_ERROR_STOP=1 -U testuser -d testdb -c "
    create table if not exists torture(
      id int primary key, s_null text, s_empty text, s_comma text, s_quote text, s_nl text,
      n numeric(10,2), big int8, b bytea, flag boolean, ts timestamptz, cjk text, emoji text);
    truncate torture;
    insert into torture values
     (1, null, '', 'a,b', 'he said \"hi\"', E'li\nnha', 8.90, 9007199254740993,
      '\x01020aff'::bytea, true, '2024-03-05 14:30:00+00', '日本語テキスト', '🚀🔥'),
     (2, null, '', 'x', 'y', 'z', -0.01, 123, null, false, null, '中文', '✅');"
}

seed_mysql() {
    # --default-character-set matters: the client defaults to latin1 and would
    # store double-encoded text that reads back as mojibake.
    docker exec nvdb-my mysql --default-character-set=utf8mb4 -uroot -p"$PW" testdb -e "
    create table if not exists torture(id int primary key, s_null text, s_empty text,
      s_comma text, n decimal(10,2), flag boolean, cjk text);
    truncate torture;
    insert into torture values (1,null,'','a,b',8.90,true,'日本語'),(2,null,'','x',-0.01,false,'中文');"
}

seed_mongo() {
    docker exec nvdb-mongo mongosh --quiet -u root -p "$PW" --authenticationDatabase admin shop --eval '
    db.orders.drop();
    db.orders.insertMany([
      {_id:1, cust:{name:"Ann",city:"Lisbon"}, total:10.5, tags:["a","b"], when:new Date("2024-01-02"), paid:true},
      {_id:2, cust:{name:"Bob, Jr"}, total:NumberDecimal("99.99"), tags:[], when:new Date("2024-02-03"), paid:false}
    ]);'
}

seed_mssql() {
    docker exec nvdb-ms /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_PW" -C -b -Q "
    if object_id('dbo.torture') is not null drop table dbo.torture;
    create table dbo.torture(id int primary key, s_null nvarchar(100), s_empty nvarchar(100),
      s_comma nvarchar(100), n decimal(10,2), flag bit, cjk nvarchar(100));
    insert into dbo.torture values (1,null,'','a,b',8.90,1,N'日本語'),(2,null,'','x',-0.01,0,N'中文');"
}

up() {
    docker run -d --name nvdb-pg -p 15432:5432 \
        -e POSTGRES_USER=testuser -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=testdb postgres:17 >/dev/null
    docker run -d --name nvdb-my -p 13306:3306 \
        -e MYSQL_ROOT_PASSWORD="$PW" -e MYSQL_DATABASE=testdb mysql:9 >/dev/null
    docker run -d --name nvdb-mongo -p 17017:27017 \
        -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$PW" mongo:7 >/dev/null
    # The SQL Server image is amd64 only and runs emulated on Apple silicon,
    # which is why it gets the longest wait.
    docker run -d --name nvdb-ms -p 11433:1433 \
        -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$MSSQL_PW" mcr.microsoft.com/mssql/server:2022-latest >/dev/null

    printf 'seeding postgres'
    retry postgres seed_postgres
    printf 'seeding mysql'
    retry mysql seed_mysql
    printf 'seeding mongo'
    retry mongo seed_mongo
    printf 'seeding sqlserver'
    retry sqlserver seed_mssql

    rm -f /tmp/neogrip-test.sqlite /tmp/neogrip-test.duckdb
    sqlite3 /tmp/neogrip-test.sqlite "create table torture(id integer primary key, s_null text,
      s_empty text, s_comma text, cjk text);
      insert into torture values (1,null,'','a,b','日本語'),(2,null,'','x','中文');"
    # No duckdb file is seeded here: a DuckDB file can only be opened by the
    # version that wrote it, so the tests create it through the same JDBC
    # driver they then read it with.
    echo "sqlite ready"
    echo "all servers up and seeded"
}

down() {
    docker rm -f nvdb-pg nvdb-my nvdb-mongo nvdb-ms >/dev/null 2>&1 || true
    rm -f /tmp/neogrip-test.sqlite /tmp/neogrip-test.duckdb
    echo "servers removed"
}

case "${1:-up}" in
    up) up ;;
    down) down ;;
    *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
