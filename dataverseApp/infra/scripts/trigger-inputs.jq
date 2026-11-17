def dvvalue($value; $path):
  if $path == null or $path == "" then $value
  elif ($value | type) == "object" and ($value | has($path)) then $value[$path]
  else reduce ($path | split("/") | map(split(".")) | flatten | map(select(. != "")))[] as $part
    ($value; if type == "object" then .[$part] else null end)
  end;

def dvresolve($swagger; $schema):
  if $schema["$ref"] then
    if ($schema["$ref"] | startswith("#/") | not) then error("External connector schema reference.")
    else dvvalue($swagger; $schema["$ref"][2:]) as $target
      | if $target == null then error("Missing connector schema reference.")
        else dvresolve($swagger; $target) + ($schema | del(.["$ref"])) end
    end
  else $schema end;

def dvoperation($swagger; $id):
  [ $swagger.paths | to_entries[] as $route | $route.value | to_entries[]
    | select(.key | IN("get", "post", "put", "patch", "delete"))
    | select(.value.operationId == $id)
    | {route: $route.key, method: (.key | ascii_upcase),
       parameters: [ (($route.value.parameters // []) + (.value.parameters // []))[]
                     | dvresolve($swagger; .) ]} ] as $matches
  | if ($matches | length) != 1 then error("Connector operation missing or ambiguous: " + $id)
    else $matches[0] end;

def dvdefinitions:
  [
    {functionName: "OnDataverseRowChanged", operationName: "SubscribeWebhookTrigger"},
    {functionName: "OnDataverseActionPerformed", operationName: "BusinessEventsTrigger"},
    {functionName: "OnDataverseRowAdded", operationName: "SubscribeOnNewItems"},
    {functionName: "OnDataverseRowModified", operationName: "SubscribeOnUpdatedItems"},
    {functionName: "OnDataverseRowDeleted", operationName: "SubscribeOnDeletedItems"}
  ];

def dvhidden:
  .readOnly == true or .["x-ms-notification-url"] == true or .["x-ms-visibility"] == "internal";

def dvvalid($swagger; $input; $value):
  dvresolve($swagger; $input) as $schema
  | ($value != null) and
    (if $schema | has("enum") then any($schema.enum[]; . == $value) else true end) and
    (if $schema.type == "object" then
       ($value | type) == "object" and
       all(($schema.required // [])[]; . as $name
         | (dvresolve($swagger; $schema.properties[$name]) | dvhidden) or ($value | has($name))) and
       all($value | to_entries[]; . as $entry
         | ($schema.properties | has($entry.key)) and dvvalid($swagger; $schema.properties[$entry.key]; $entry.value))
     elif $schema.type == "array" then
       ($value | type) == "array" and
       ($schema.minItems == null or ($value | length) >= $schema.minItems) and
       ($schema.maxItems == null or ($value | length) <= $schema.maxItems) and
       all($value[]; dvvalid($swagger; $schema.items; .))
     elif $schema.type == "string" then
       ($value | type) == "string" and
       ($schema.minLength == null or ($value | length) >= $schema.minLength) and
       ($schema.maxLength == null or ($value | length) <= $schema.maxLength) and
       ($schema.pattern == null or ($value | test($schema.pattern)))
     elif $schema.type == "boolean" then ($value | type) == "boolean"
     elif $schema.type == "number" or $schema.type == "integer" then
       ($value | type) == "number" and ($value | isfinite) and
       ($schema.type != "integer" or ($value | floor) == $value) and
       ($schema.minimum == null or $value >= $schema.minimum) and
       ($schema.maximum == null or $value <= $schema.maximum)
     else false end);

def dvvalidate($swagger; $triggers):
  if ($triggers | type) != "array" or ($triggers | length) == 0 then
    error("Select at least one trigger; no configurations have been changed.")
  elif ($triggers | map(.functionName) | unique | length) != ($triggers | length) then
    error("Duplicate saved Dataverse selections.")
  else
    $triggers[] as $trigger
    | if any(dvdefinitions[]; .functionName == $trigger.functionName and .operationName == $trigger.operationName) | not then
        error("Invalid saved Dataverse selection.")
      else dvoperation($swagger; $trigger.operationName).parameters
        | map(select(.name != "connectionId" and (dvhidden | not))
              | . + {inputName: (if .in == "body" then "body" else .name end)}) as $expected
        | if ($trigger.parameters | type) != "array" or
             ($trigger.parameters | map(.name) | unique | length) != ($trigger.parameters | length) or
             (all($trigger.parameters[]; . as $p
                 | any($expected[]; .inputName == $p.name and dvvalid($swagger; (if .in == "body" then .schema else . end); $p.value))) | not) or
             (all($expected[] | select(.required == true); .inputName as $name
                 | any($trigger.parameters[]; .name == $name)) | not)
          then error("Missing or invalid saved Dataverse input.")
          else empty end
      end
  end;

def dvdynamic:
  (.["x-ms-dynamic-list"] // .["x-ms-dynamic-values"]) as $extension
  | if $extension != null and $extension.operationId == null then
      $extension + ($extension.dynamicState.extension // $extension.dynamicState)
    else $extension end;

def dvreferences($swagger; $schema):
  dvresolve($swagger; $schema) as $resolved
  | [ (($resolved | dvdynamic).parameters // {})[] | select(type == "object")
      | (.parameterReference // .parameter) | select(. != null) ] +
    [ ($resolved.properties // {})[] | dvreferences($swagger; .)[] ];

def dvfieldorder($swagger; $schema):
  def order($pending; $done):
    if ($pending | length) == 0 then $done
    else [ $pending[] as $name
      | dvreferences($swagger; $schema.properties[$name]) | map(split("/") | map(split(".")) | flatten | last)
      | map(select(. != $name and (. as $dep | $pending | index($dep)) != null))
      | select(length == 0) | $name ] as $ready
      | if ($ready | length) == 0 then error("Cyclic connector picker dependencies.")
        else order($pending - [$ready[0]]; $done + [$ready[0]]) end
    end;
  order(($schema.properties | keys_unsorted); []);

def dvbindings($extension; $answers):
  reduce (($extension.parameters // {}) | to_entries[]) as $binding ({};
    .[$binding.key] = (
      if ($binding.value | type) != "object" then $binding.value
      elif $binding.value.parameterReference != null or $binding.value.parameter != null then
        ($binding.value.parameterReference // $binding.value.parameter) as $reference
        | dvvalue($answers; $reference) as $top
        | (if $top != null then $top else dvvalue($answers.body; $reference) end) as $value
        | if $value == null then error("Select " + $reference + " before resolving the picker.") else $value end
      elif $binding.value | has("value") then $binding.value.value
      else error("Unsupported connector picker binding.") end));

def dvrequest($swagger; $id; $values):
  dvoperation($swagger; $id) as $operation
  | reduce ($operation.parameters[] | select(.name != "connectionId")) as $p
      ({method: $operation.method, path: ($operation.route | sub("^/\\{connectionId\\}"; ""))};
       (if $values | has($p.name) then $values[$p.name] else $p.default end) as $value
       | if $value == null then
           if $p.required then error("Picker requires " + $p.name) else . end
         elif $p.in == "path" then
           ($value | tostring | @uri | if $p["x-ms-url-encoding"] == "double" then @uri else . end) as $encoded
           | .path |= (split("{" + $p.name + "}") | join($encoded))
         elif $p.in == "query" then .queries[$p.name] = $value
         elif $p.in == "header" then .headers[$p.name] = $value
         elif $p.in == "body" then .body = $value
         else . end)
  | if .path | test("\\{[^}]+\\}") then error("Unresolved picker path.") else . end;

def dvchoices($extension; $response):
  ($extension.itemsPath // $extension["value-collection"]) as $collection
  | (if $collection != null then dvvalue($response; $collection)
     elif ($response | type) == "array" then $response else $response.value end) as $items
  | if ($items | type) != "array" then error("Connector returned a malformed list.")
    else [ $items[]
      | dvvalue(.; ($extension.itemValuePath // $extension["value-path"])) as $value
      | dvvalue(.; ($extension.itemTitlePath // $extension["value-title"])) as $title
      | select(($value | type) | IN("string", "number", "boolean"))
      | select($value != "" or ($title != null and $title != ""))
      | {value: $value, label: (if $title != null and $title != "" then $title else $value end | tostring)} ]
    end;
