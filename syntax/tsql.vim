" T-SQL. The treesitter sql parser errors on most real T-SQL -- [bracketed
" names], TOP, @variables, MERGE, DECLARE, GO -- so a SQL Server buffer uses
" this instead (see lua/db/dialect.lua).
if exists("b:current_syntax")
    finish
endif

syn case ignore

syn keyword tsqlStatement select insert update delete merge truncate exec execute
syn keyword tsqlStatement create alter drop declare set print raiserror throw
syn keyword tsqlStatement begin end commit rollback transaction tran save go
syn keyword tsqlStatement if else while break continue return goto waitfor try catch
syn keyword tsqlStatement grant revoke deny use backup restore checkpoint

syn keyword tsqlKeyword from where group by having order asc desc into values
syn keyword tsqlKeyword inner left right full outer cross apply join on union all
syn keyword tsqlKeyword except intersect as distinct top percent ties offset fetch
syn keyword tsqlKeyword next rows only with recursive over partition between like
syn keyword tsqlKeyword in exists not and or is null case when then else output
syn keyword tsqlKeyword matched source target using when primary key foreign
syn keyword tsqlKeyword references constraint unique clustered nonclustered index
syn keyword tsqlKeyword identity default check table view procedure proc function
syn keyword tsqlKeyword trigger schema database column add nocount parseonly noexec
syn keyword tsqlKeyword xact_abort rowcount tran_abort readonly nolock rowlock

syn keyword tsqlType int bigint smallint tinyint bit decimal numeric money
syn keyword tsqlType smallmoney float real datetime datetime2 smalldatetime date
syn keyword tsqlType time datetimeoffset char varchar text nchar nvarchar ntext
syn keyword tsqlType binary varbinary image uniqueidentifier xml sql_variant
syn keyword tsqlType hierarchyid geography geometry cursor table rowversion max

syn keyword tsqlFunction count sum avg min max row_number rank dense_rank ntile
syn keyword tsqlFunction cast convert try_cast try_convert isnull coalesce nullif
syn keyword tsqlFunction getdate getutcdate sysdatetime dateadd datediff datepart
syn keyword tsqlFunction datename eomonth format len substring charindex patindex
syn keyword tsqlFunction replace stuff left right ltrim rtrim upper lower concat
syn keyword tsqlFunction concat_ws string_agg string_split iif choose newid
syn keyword tsqlFunction object_id object_name scope_identity error_message
syn keyword tsqlFunction error_number error_severity error_line has_dbaccess
syn keyword tsqlFunction json_value json_query json_modify openjson isjson

" @@TRANCOUNT and friends, then plain @variables and #temp tables.
syn match tsqlGlobalVariable "@@\w\+"
syn match tsqlVariable "@\w\+"
syn match tsqlTempTable "#\{1,2}\w\+"

" A bracketed identifier is a name, not a string: [order] is a legal column.
syn region tsqlIdentifier start="\[" end="\]" oneline
syn region tsqlString start="N\?'" skip="''" end="'"
syn match tsqlNumber "\<\d\+\(\.\d*\)\?\>"
syn match tsqlComment "--.*$" contains=@Spell
syn region tsqlComment start="/\*" end="\*/" contains=tsqlComment,@Spell
syn match tsqlOperator "[-+*/%=<>!]\|<>\|>=\|<=\|!=\|+=\|-="

hi def link tsqlStatement Statement
hi def link tsqlKeyword Keyword
hi def link tsqlType Type
hi def link tsqlFunction Function
hi def link tsqlGlobalVariable Constant
hi def link tsqlVariable Identifier
hi def link tsqlTempTable Identifier
hi def link tsqlIdentifier Identifier
hi def link tsqlString String
hi def link tsqlNumber Number
hi def link tsqlComment Comment
hi def link tsqlOperator Operator

let b:current_syntax = "tsql"
