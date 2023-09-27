// Copyright (c) 2023 WSO2 LLC (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/io;
import ballerina/log;
import ballerina/yaml;

# Provides extracted tools and service URL from the OpenAPI specification.
public type HttpApiSpecification record {|
    # Extracted service URL from the OpenAPI specification if there is any
    string serviceUrl?;
    # Extracted Http tools from the OpenAPI specification
    HttpTool[] tools;
|};

# Defines additional information to be extracted from the OpenAPI specification.
public type AdditionInfoFlags record {|
    # Flag to extract description of parameters and schema attributes from the OpenAPI specification
    boolean extractDescription = false;
    # Flag to extract default values of parameters and schema attributes from the OpenAPI specification
    boolean extractDefault = false;
|};

# Extracts the Http tools from the given OpenAPI specification file.
#
# + filePath - Path to the OpenAPI specification file (should be JSON or YAML)
# + additionInfoFlags - Flags to extract additional information from the OpenAPI specification
# + return - A record with the list of extracted tools and the service URL (if available)
public isolated function extractToolsFromOpenApiSpecFile(string filePath, *AdditionInfoFlags additionInfoFlags) returns
HttpApiSpecification & readonly|error {
    map<json> openApiSpec;
    if filePath.endsWith(".yaml") || filePath.endsWith(".yml") {
        openApiSpec = check yaml:readFile(filePath).ensureType();
    }
    else if filePath.endsWith(".json") {
        openApiSpec = check io:fileReadJson(filePath).ensureType();
    }
    else {
        return error("Unsupported file type. Supported file types are .json, .yaml or .yml");
    }
    return extractToolsFromOpenApiJsonSpec(openApiSpec, additionInfoFlags);
}

# Extracts the Http tools from the given OpenAPI specification as a JSON 
#
# + openApiSpec - A valid OpenAPI specification in JSON format
# + additionInfoFlags - Flags to extract additional information from the OpenAPI specification
# + return - A record with the list of extracted tools and the service URL (if available)
public isolated function extractToolsFromOpenApiJsonSpec(map<json> openApiSpec, *AdditionInfoFlags additionInfoFlags) returns
HttpApiSpecification & readonly|error {
    OpenApiSpec spec = check parseOpenApiSpec(openApiSpec);
    OpenApiSpecVisitor visitor = new (additionInfoFlags);
    return check visitor.visit(spec).cloneReadOnly();
}

# Parses the given OpenAPI specification as a JSON to a OpenApiSpec object.
#
# + openApiSpec - A valid OpenAPI specification in JSON format
# + return - A OpenApiSpec object
public isolated function parseOpenApiSpec(map<json> openApiSpec) returns OpenApiSpec|UnsupportedOpenApiVersion|OpenApiParsingError {
    if !openApiSpec.hasKey("openapi") {
        return error UnsupportedOpenApiVersion("OpenAPI version is not specified in the specification.");
    }
    json version = openApiSpec.get("openapi");
    if version !is string || !version.matches(re `3\.0\..`) {
        return error UnsupportedOpenApiVersion("Unsupported OpenAPI version. Supports specifications with version 3.x.x only.");
    }
    OpenApiSpec|error parseSpec = openApiSpec.cloneWithType();
    if parseSpec is OpenApiSpec {
        return parseSpec;
    }
    return error OpenApiParsingError("Error while parsing the OpenAPI specification.", cause = parseSpec);
}

class OpenApiSpecVisitor {
    private map<ComponentType> referenceMap = {};
    private final HttpTool[] tools = [];
    private final AdditionInfoFlags additionalInfoFlags;

    isolated function init(AdditionInfoFlags additionalInfoFlags = {}) {
        self.additionalInfoFlags = additionalInfoFlags.cloneReadOnly();
    }

    isolated function visit(OpenApiSpec openApiSpec) returns HttpApiSpecification|error {
        string? serviceUrl = self.visitServers(openApiSpec.servers);
        self.referenceMap = self.visitComponents(openApiSpec.components);

        Paths? paths = openApiSpec.paths;
        error? parsingError = ();
        if paths !is () {
            parsingError = trap check self.visitPaths(paths);
        }
        if parsingError is () {
            return {
                serviceUrl,
                tools: self.tools.cloneReadOnly()
            };
        }
        if parsingError.message().includes("{ballerina}StackOverflow") {
            return error ParsingStackOverflowError("Parsing failed due to either a cyclic reference or the excessive length of the specification.", cause = parsingError);
        }
        return error OpenApiParsingError("Error while parsing the OpenAPI specification.", cause = parsingError);
    }

    private isolated function visitServers(Server[]? servers) returns string? {
        if servers is () || servers.length() < 1 {
            return ();
        }
        if servers.length() > 1 {
            log:printWarn("Multiple server urls are defined in the OpenAPI specification. If not specified, toolkit will use " + servers[0].url);
        }
        return servers[0].url;
    }

    private isolated function visitComponents(Components? components) returns map<ComponentType> {
        if components is () {
            return {};
        }
        map<ComponentType> referenceMap = {};
        foreach [string, anydata] [componentType, componentMap] in components.entries() {
            if componentMap !is map<ComponentType|Reference> {
                continue;
            }
            foreach [string, ComponentType|Reference] [componentName, component] in componentMap.entries() {
                string ref = string `#/${OPENAPI_COMPONENTS_KEY}/${componentType}/${componentName}`;
                referenceMap[ref] = component;
            }
        }
        return referenceMap;
    }

    private isolated function visitPaths(Paths paths) returns error? {
        foreach [string, PathItem|Reference] [pathUrl, pathItem] in paths.entries() {
            if pathItem is Reference {
                check self.visitPathItem(pathUrl, check self.visitReference(pathItem).ensureType());
            } else if pathItem is PathItem {
                check self.visitPathItem(pathUrl, pathItem);
            } else {
                return error("Unsupported path item type.", 'type = typeof pathItem);
            }
        }
    }

    private isolated function visitPathItem(string pathUrl, PathItem pathItem) returns error? {
        HttpMethod[] supportedMethods = [GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH];
        foreach HttpMethod httpMethod in supportedMethods {
            string method = httpMethod.toLowerAscii();
            if !pathItem.hasKey(method) {
                continue;
            }
            anydata operation = pathItem.get(method);
            if operation is Operation {
                check self.visitOperation(pathUrl, httpMethod, operation);
            }
        }
    }

    private isolated function visitOperation(string path, HttpMethod method, Operation operation) returns error? {
        string? description = operation.description ?: operation.summary;
        if description is () {
            return error IncompleteSpecificationError(string `A summary or description is mandatory for API paths. But it is missing for the resource "[${method}]:${path}"`);
        }
        string? name = operation.operationId;
        if name is () {
            return error(string `OperationId is mandotory for API paths. But, tt is missing for the resource "[${method}]:${path}"`);
        }

        // resolve parameters
        ParameterSchema? queryParameters = ();
        ParameterSchema? pathParameters = ();
        (Parameter|Reference)[]? parameters = operation.parameters;
        if parameters !is () {
            {pathParameters, queryParameters} = check self.visitParameters(parameters);
        }

        RequestBodySchema? requestBody = ();
        RequestBody|Reference? requestBodySchema = operation.requestBody;
        if requestBodySchema is Reference {
            RequestBody resolvedRequestBody = check self.visitReference(requestBodySchema).ensureType();
            requestBody = check self.visitRequestBody(resolvedRequestBody);
        } else if requestBodySchema is RequestBody {
            requestBody = check self.visitRequestBody(requestBodySchema);
        }

        self.tools.push({
            name,
            description,
            path,
            method,
            queryParameters,
            pathParameters,
            requestBody
        });
    }

    private isolated function visitContent(map<MediaType> content) returns Schema|error {
        // check for json content
        foreach [string, MediaType] [key, value] in content.entries() {
            if key.trim().matches(re `(application/.*json|text/.*plain|\*/\*)`) {
                return value.schema;
            }
        }
        return error("Only json content is supported.", availableContentTypes = content.keys());
    }

    private isolated function visitRequestBody(RequestBody requestBody) returns RequestBodySchema|error {
        map<MediaType> content = requestBody.content;
        Schema schema = check self.visitContent(content);
        return self.visitSchema(schema).ensureType();
    }

    isolated function verifyParameterType(JsonSubSchema parameterSchema) returns ParameterType|error {
        if parameterSchema is PrimitiveInputSchema {
            return parameterSchema;
        }
        if parameterSchema !is ArrayInputSchema {
            return error("Unsupported HTTP parameter type.", cause = "Expected only `PrimitiveType` or array type, but found: " + (typeof parameterSchema).toString());
        }
        JsonSubSchema items = parameterSchema.items;
        if items !is PrimitiveInputSchema {
            return error("Unsupported HTTP parameter type.", cause = "Expected only `PrimitiveType` values for array type parameters, but found: " + (typeof items).toString());
        }
        json[]? default = parameterSchema.default;
        if default !is PrimitiveType? {
            return error("Unsupported default value for array type parameter.", cause = "Expected a `PrimitiveType` items in the array, but found: " + (typeof default).toString());
        }
        return {
            items,
            default,
            description: parameterSchema?.description
        };
    }

    private isolated function visitParameters((Parameter|Reference)[] parameters) returns record {|ParameterSchema? pathParameters = (); ParameterSchema? queryParameters = ();|}|error {
        map<ParameterType> pathParams = {};
        map<ParameterType> queryParams = {};
        string[] pathRequired = [];
        string[] queryRequired = [];

        foreach Parameter|Reference param in parameters {
            Parameter resolvedParameter;
            if param is Reference {
                resolvedParameter = check self.visitReference(param).ensureType();
            } else if param is Parameter {
                resolvedParameter = param;
            } else {
                continue;
            }

            Schema? schema;
            map<MediaType>? content = resolvedParameter.content;
            if content is () {
                schema = resolvedParameter.schema;
            }
            else {
                schema = check self.visitContent(content);
            }

            if schema is () {
                continue;
            }
            string? style = resolvedParameter.style;
            boolean? explode = resolvedParameter.explode;
            if resolvedParameter.'in == OPENAPI_QUERY_PARAM_LOC_KEY {
                if style !is () && style != OPENAPI_QUERY_PARAM_SUPPORTED_STYLE {
                    return error("Supported only the query parameters with style=" + OPENAPI_QUERY_PARAM_SUPPORTED_STYLE);
                }
                if explode !is () && !explode {
                    return error("Supported only the query parmaters with explode=true");
                }
                ParameterType parameterType = check self.verifyParameterType(check self.visitSchema(schema));
                string name = resolvedParameter.name;
                if resolvedParameter.required == true {
                    queryRequired.push(name);
                }
                queryParams[name] = parameterType;
            } else if resolvedParameter.'in == OPENAPI_PATH_PARAM_LOC_KEY {
                if style !is () && style != OPENAPI_PATH_PARAM_SUPPORTED_STYLE {
                    return error("Supported only the path parameters with style=" + OPENAPI_PATH_PARAM_SUPPORTED_STYLE);
                }
                if explode !is () && explode {
                    return error("Supported only the path parmaters with explode=false");
                }
                ParameterType parameterType = check self.verifyParameterType(check self.visitSchema(schema));
                string name = resolvedParameter.name;
                if resolvedParameter.required == true {
                    pathRequired.push(name);
                }
                pathParams[name] = parameterType;
            }
        }
        ParameterSchema pathParameters = {properties: pathParams, required: pathRequired.length() > 0 ? pathRequired : ()};
        ParameterSchema queryParameters = {properties: queryParams, required: queryRequired.length() > 0 ? queryRequired : ()};
        return {
            pathParameters: pathParams.length() > 0 ? pathParameters : (),
            queryParameters: queryParams.length() > 0 ? queryParameters : ()
        };
    }

    private isolated function visitReference(Reference reference) returns ComponentType|InvalidReferenceError {
        if !self.referenceMap.hasKey(reference.\$ref) {
            return error InvalidReferenceError("Missing component object for the given reference", reference = reference.\$ref);
        }
        ComponentType|Reference component = self.referenceMap.get(reference.\$ref);
        if component is Reference {
            return self.visitReference(component);
        }
        return component;
    }

    private isolated function visitSchema(Schema schema) returns JsonSubSchema|error {
        if schema is ObjectSchema {
            return self.visitObjectSchema(schema);
        }
        if schema is ArraySchema {
            return self.visitArraySchema(schema);
        }
        if schema is PrimitiveTypeSchema {
            return self.visitPrimitiveTypeSchema(schema);
        }
        if schema is AnyOfSchema {
            return self.visitAnyOfSchema(schema);
        }
        if schema is OneOfSchema {
            return self.visitOneOfSchema(schema);
        }
        if schema is AllOfSchema {
            return self.visitAllOfSchema(schema);
        }
        if schema is NotSchema {
            return self.visitNotSchema(schema);
        }
        Schema resolvedSchema = check self.visitReference(<Reference>schema).ensureType();
        return check self.visitSchema(resolvedSchema);
    }

    private isolated function visitObjectSchema(ObjectSchema schema) returns ObjectInputSchema|error {
        ObjectInputSchema objectSchema = {
            'type: OBJECT,
            properties: {}
        };

        if schema?.properties == () {
            return objectSchema;
        }

        map<Schema> properties = <map<Schema>>schema?.properties;
        if properties.length() == 0 {
            return objectSchema;
        }

        foreach [string, Schema] [propertyName, property] in properties.entries() {
            objectSchema.properties[propertyName] = check self.visitSchema(property);
        }
        boolean|string[]? required = schema?.required;
        if required is string[] {
            objectSchema.required = required;
        }
        return objectSchema;
    }

    private isolated function visitArraySchema(ArraySchema schema) returns ArrayInputSchema|error {
        return {
            'type: ARRAY,
            items: check self.visitSchema(schema.items)
        };
    }

    private isolated function visitPrimitiveTypeSchema(PrimitiveTypeSchema schema) returns PrimitiveInputSchema|error {
        PrimitiveInputSchema inputSchmea = {
            'type: schema.'type
        };

        if self.additionalInfoFlags.extractDescription {
            inputSchmea.description = schema.description;
        }
        if self.additionalInfoFlags.extractDefault {
            inputSchmea.default = check schema?.default.ensureType();
        }

        if schema is StringSchema {
            string? pattern = schema.pattern;
            string? format = schema.format;
            if format is string && pattern is () {
                if format == "date" {
                    pattern = OPENAPI_PATTER_DATE;
                }
                else if format == "date-time" {
                    pattern = OPENAPI_PATTER_DATE_TIME;
                }
            }

            inputSchmea.format = format;
            inputSchmea.pattern = pattern;
            inputSchmea.'enum = schema.'enum;
        }
        if schema is NumberSchema {
            inputSchmea.'type = FLOAT;
        }
        return inputSchmea;
    }

    private isolated function visitAnyOfSchema(AnyOfSchema schema) returns AnyOfInputSchema|error {
        JsonSubSchema[] anyOf = from Schema element in schema.anyOf
            select check self.visitSchema(element).ensureType();
        return {
            anyOf
        };
    }

    private isolated function visitAllOfSchema(AllOfSchema schema) returns AllOfInputSchema|error {
        JsonSubSchema[] allOf = from Schema element in schema.allOf
            select check self.visitSchema(element).ensureType();
        return {
            allOf
        };
    }

    private isolated function visitOneOfSchema(OneOfSchema schema) returns OneOfInputSchema|error {
        JsonSubSchema[] oneOf = from Schema element in schema.oneOf
            select check self.visitSchema(element);
        return {
            oneOf
        };
    }

    private isolated function visitNotSchema(NotSchema schema) returns NotInputSchema|error {
        return {
            not: check self.visitSchema(schema.not)
        };
    }
}

