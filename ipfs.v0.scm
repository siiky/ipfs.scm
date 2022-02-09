(module ipfs.v0
  (
   *scheme*
   *host*
   *port*

   rpc-call
   call-uri
   call-request
   make-uri
   make-request

   reader/json
   reader/plain
   writer/file
   writer/filesystem

   make-rpc-lambda
   export-rpc-call
   )

  (import
    (except scheme
            string)
    (only chicken.base
          assert
          cute
          make-parameter
          define-constant
          o)
    (only chicken.io
          read-string)
    (only chicken.module
          export)
    (only chicken.string
          ->string)
    )

  (import
    (prefix (rename (only medea read-json)
                    (read-json read))
            |json:|)
    (rename (only uri-common make-uri)
            (make-uri uri:make))
    (rename (only intarweb make-request)
            (make-request request:make))
    (only http-client
          with-input-from-request)
    matchable)

  ;(import
  ;  (rename
  ;    (only srfi-189
  ;          either-bind
  ;          either-ref
  ;          either?
  ;          exception->either
  ;          left
  ;          left?
  ;          right
  ;          right?)
  ;    (either-bind       result-bind)
  ;    (either-ref        result-ref)
  ;    (either?           result?)
  ;    (exception->either exception->result)
  ;    (left              result/error)
  ;    (left?             result/error?)
  ;    (right             result/ok)
  ;    (right?            result/ok?)))

  (import
    (only srfi-1
          append-map
          filter)
    (only srfi-189
          just
          just?
          maybe->values
          maybe-map
          maybe?
          nothing
          nothing?)

    (only srfi-197
          chain
          chain-lambda)
    )

  (define-constant %api-base% "api")
  (define-constant %version% "v0")
  (define %nothing% (nothing))

  (define *scheme* (make-parameter 'http))
  (define *host* (make-parameter "localhost"))
  (define *port* (make-parameter 5001))

  ;; @brief Compute the HTTP path for some endpoint
  ;; @param endpoint-path List of symbols representing the path after the
  ;;   "/api/v0/". Example: '(commands completion bash) for the final HTTP path
  ;;   "/api/v0/commands/completion/bash"
  ;; @returns A list suitable to be given to uri-common.make-uri as the #:path
  ;;   parameter. Example: '(/ "api" "v0" "commands" "completion" "bash")
  (define (http-api-path endpoint-path)
    `(/ ,%api-base% ,%version% ,@(map symbol->string endpoint-path)))

  (define reader/json json:read)
  (define reader/plain read-string)

  (define (writer/file path #!key filename headers)
    (let ((filename (or filename path))
          (filename-entry (if filename `(#:filename ,filename) '()))
          (headers-entry (if headers `(#:headers ,headers) '())))
      `((,filename #:file ,path ,@filename-entry ,@headers-entry))))

  (define (writer/filesystem)
    ; TODO: Implement reading files & traversing a file system to write the
    ;       request body.
    "")

  (define (make-uri #!key (scheme (*scheme*)) (host (*host*)) (port (*port*)) path query)
    (uri:make
      #:scheme scheme
      #:host host
      #:port port
      #:path path
      #:query query))

  (define (make-request uri #!key (method 'POST))
    (request:make
      #:method method
      #:uri uri))

  (define (call-request request #!key reader writer)
    (with-input-from-request request writer reader))

  (define (call-uri uri #!key (method 'POST) reader writer)
    (call-request (make-request uri #:method method) #:reader reader #:writer writer))


  (define kv-key car)
  (define kv-value cdr)
  (define kv cons)
  (define (kv-value-pred pred?) (o pred? kv-value))
  (define ((kv-value-map mapper) p)
    (kv (kv-key p) (mapper (kv-value p))))

  (define make-query
    (chain-lambda
      (map
        ; (K, Maybe V) -> Maybe (K, V)
        (match-lambda ((k . v) (maybe-map (cute kv k <>) v)))
        _)
      (filter just? _)
      (append-map
        (o
          ; (K, V) -> [(K, V)]
          list
          ; (K, [V]) -> [(K, V)]
          ;((match-lambda ((k . v) (map (cute kv k <>) v))) _)
          ; Just (K, V) -> (K, V)
          maybe->values)
        _)))


  (define (->maybe x)
    (if (maybe? x)
      x
      (just x)))

  (define (->list x) (if (list? x) x (list x)))
  (define ((list-wrapper type-cast) name value)
    (->list (type-cast name value)))
  (define ((type-wrapper type-cast) argname value)
    (chain value
           (->maybe _)
           ; TODO: Use maybe-bind instead so that type functions may fail
           (maybe-map (cute type-cast argname <>) _)))

  (define (*->bool name value) (if value "true" "false"))
  (define (*->string name value) (->string value))
  (define (*->number name n)
    (assert (number? n) (string-append (symbol->string name) " must be an integer"))
    n)

  ;; NOTE: The only types listed on the official documentation, as of now, are:
  ;;   * bool
  ;;   * int, uint, int64
  ;;   * string
  ;;   * array
  ;; @see https://docs.ipfs.io/reference/http/api
  ;; TODO: Find the difference between the integer types for the API
  (define bool (type-wrapper *->bool))
  (define int (type-wrapper *->number))
  (define string (type-wrapper *->string))

  ; TODO
  (define (array type)
    (type-wrapper (type-wrapper bool)))


  (define (rpc-call path arguments flags #!key reader writer)
    (chain (append (make-query arguments)
                   (make-query flags))
           (make-uri #:path path #:query _)
           (call-uri _ #:reader reader #:writer writer)))

  (define (yes argname value)
    (assert (not (nothing? value))
            (string-append (symbol->string argname) " is required"))
    value)
  (define (no argname value) value)

  ;; @brief Creates a procedure that can be used to make an RPC call.
  ;;
  ;; @param default-reader/writer The default reader & writer thunks given to
  ;;   with-input-from-request, if none is given at the tiem of the call. Must
  ;;   be a list, of up to 2 elements, of the form (reader writer). If not
  ;;   given, reader defaults to reader/json and writer defaults to #f.
  ;;
  ;; @param path A list of the form (component ...) that denotes the path of
  ;;   the endpoint.
  ;;
  ;; @param arguments A list of the form ((argument type required?) ...) that
  ;;   specifies the list of arguments. `argument` is the argument's name, used
  ;;   as the keyword argument in the defined procedure. `type` is the type
  ;;   procedure that corresponds to the expected type. `required?` is `yes` or
  ;;   `no` according to whether the argument is required or not. These are
  ;;   sent to the server in the query string with the key `arg`.
  ;;
  ;; @param flags A list of the form ((flag type) ...) that specifies the list
  ;;   of flags. `flag` is the name of the flag, used for both the keyword
  ;;   argument in the defined procedure, as well as the key in the query
  ;;   string sent to the server. `type` is the type procedure that corresponds
  ;;   to the expected type.
  ;;
  ;; Used in the form (make-rpc-lambda path arguments flags), that is:
  ;;
  ;; (make-rpc-lambda
  ;;   (default-reader default-writer)
  ;;   (component ...)
  ;;   ((argument atype required?) ...)
  ;;   ((flag ftype) ...))
  ;;
  ;; `required?` can be either `yes` or `no`. The type procedures are `bool`,
  ;;   `int`, `string`, and `array` (TBI).
  ;;
  ;; @see export-rpc-call
  (define-syntax make-rpc-lambda
    (syntax-rules ()
      ((make-rpc-lambda _ () _ _)
       (syntax-error "The endpoint path must not be empty"))

      ((make-rpc-lambda ()            path arguments flags)
       (make-rpc-lambda (reader/json) path arguments flags))

      ((make-rpc-lambda (default-reader)    path arguments flags)
       (make-rpc-lambda (default-reader #f) path arguments flags))

      ((make-rpc-lambda
         (default-reader default-writer)
         (component ...)
         ((argument atype required?) ...)
         ((flag ftype) ...))

       (let ((path (http-api-path '(component ...))))
         (lambda (#!key
                  (reader default-reader)
                  (writer default-writer)
                  (argument %nothing%) ...
                  (flag %nothing%) ...)
           (rpc-call path
                     `((arg . ,(atype 'argument (required? 'argument argument))) ...)
                     `((flag . ,(ftype 'flag flag)) ...)
                     #:reader reader
                     #:writer writer))))))

  (import procedural-macros)
  (import-for-syntax
    bindings
    (only chicken.syntax strip-syntax)
    (only srfi-13 string-join)
    (only srfi-197 chain-lambda))

  ;; @brief Defines and exports an RPC procedure created with make-rpc-lambda.
  ;;
  ;; Used in the form
  ;;   (export-rpc-call (default-reader default-writer) (path . arguments) . flags)
  ;; or in more detail
  ;;   (export-rpc-call
  ;;     (default-reader default-writer)
  ;;     ((component ...)
  ;;      (argument type required?) ...)
  ;;     (flag type) ...)
  ;;
  ;; @see make-rpc-lambda
  (define-macro
    (export-rpc-call reader/writer (path . arguments) . flags)
    (with-implicit-renaming
      (=? %name)
      (let* ((make-name
               (chain-lambda
                 (map (o symbol->string strip-syntax) _)
                 (string-join _ "/")
                 (string->symbol _)))
             (%name (make-name path)))
        `(begin
           (export ,%name)
           (define ,%name (make-rpc-lambda ,reader/writer ,path ,arguments ,flags))))))

  (export-rpc-call
    ()
    ((add))
    (quiet bool)
    (quieter bool)
    (silent bool)
    (progress bool)
    (trickle bool)
    (only-hash bool)
    (wrap-with-directory bool)
    (chunker string)
    (pin bool)
    (raw-leaves bool)
    (nocopy bool)
    (fscache bool)
    (cid-version int)
    (hash string)
    (inline bool)
    (inline-limit int))

  (export-rpc-call (reader/plain) ((cat) (path string yes)) (offset int) (length int))
  (export-rpc-call () ((commands)) (flags bool))
  (export-rpc-call () ((commands completion bash)))
  (export-rpc-call () ((cid codecs)))
  )
