/// Reflection-based conversion of D values to `std.json.JSONValue`.
module dex.jsonx;

import std.conv : ConvException, to;
import std.json : JSONType, JSONValue;
import std.math : isFinite;
import std.string : format, strip, toLower;
import std.traits;
import std.typecons : Nullable;

import dex.errors : HttpError;

/// UDA marking a struct/class field as optional during `fromJSONValue` / `req.bind!T`,
/// even when its default value equals the type's `.init`.
enum optional;

/// Convert any supported D value into a `JSONValue`.
///
/// Supported: `JSONValue`, null, bool, integral and floating-point values,
/// strings, enums (as member names), `Nullable`, arrays, associative arrays,
/// pointers, structs and classes. Struct/class fields are serialized by name.
/// A type can customize serialization by defining `JSONValue toJSON() const`.
JSONValue toJSONValue(T)(auto ref T value)
{
    // Strip const/immutable/shared so e.g. `const JSONValue` and
    // `const Nullable!int` take the same branch as their mutable forms.
    alias U = Unqual!T;

    static if (is(U == JSONValue))
    {
        // Serialization only reads the result; dropping const is fine here.
        return cast(JSONValue) value;
    }
    else static if (is(U == typeof(null)))
    {
        return JSONValue(null);
    }
    else static if (is(U == bool))
    {
        return JSONValue(value);
    }
    else static if (is(U == enum))
    {
        return JSONValue(to!string(value));
    }
    else static if (isIntegral!U)
    {
        static if (isUnsigned!U)
            return JSONValue(cast(ulong) value);
        else
            return JSONValue(cast(long) value);
    }
    else static if (isFloatingPoint!U)
    {
        const d = cast(double) value;
        return isFinite(d) ? JSONValue(d) : JSONValue(null);
    }
    else static if (isSomeChar!U)
    {
        return JSONValue(to!string(value));
    }
    else static if (isSomeString!U)
    {
        static if (is(T : string))
            return JSONValue(value);
        else
            return JSONValue(to!string(value)); // char[], wstring, dstring
    }
    else static if (is(U == Nullable!V, V))
    {
        return value.isNull ? JSONValue(null) : toJSONValue(value.get);
    }
    else static if (isStaticArray!U || isDynamicArray!U)
    {
        JSONValue[] items;
        items.reserve(value.length);
        foreach (ref item; value)
            items ~= toJSONValue(item);
        return JSONValue(items);
    }
    else static if (isAssociativeArray!U)
    {
        JSONValue[string] object;
        foreach (key, ref item; value)
            object[to!string(key)] = toJSONValue(item);
        return JSONValue(object);
    }
    else static if (isPointer!U)
    {
        return value is null ? JSONValue(null) : toJSONValue(*value);
    }
    else static if (is(U == struct) || is(U == class))
    {
        static if (is(U == class))
        {
            if (value is null)
                return JSONValue(null);
        }

        static if (hasMember!(U, "toJSON") &&
                   is(typeof(value.toJSON()) : JSONValue))
        {
            return value.toJSON();
        }
        else
        {
            JSONValue[string] object;
            static if (is(U == class) && BaseClassesTuple!U.length > 0)
            {
                alias Base = BaseClassesTuple!U[0];
                auto baseObject = toJSONValue(cast(Base) value);
                foreach (key, item; baseObject.object)
                    object[key] = item;
            }
            alias fieldNames = FieldNameTuple!U;
            static assert(fieldNames.length == U.tupleof.length,
                          "Cannot reflect over fields of " ~ U.stringof);
            foreach (i, ref field; value.tupleof)
                object[fieldNames[i]] = toJSONValue(field);
            return JSONValue(object);
        }
    }
    else
    {
        static assert(false, "Cannot serialize " ~ T.stringof ~ " to JSON");
    }
}

/// Deserialize a `JSONValue` into D type `T`.
///
/// Supports primitives, strings, enums, `Nullable!V`, arrays, associative
/// arrays, and nested structs/classes (including default field values and the
/// `@optional` UDA). Throws `HttpError` (`errorStatus`, defaulting to `422`)
/// with a field-path diagnostic when a required field is missing or a type
/// mismatches. Types may define `static T fromJSON(JSONValue)` to customize
/// deserialization.
T fromJSONValue(T)(JSONValue value, string fieldPath = "", ushort errorStatus = 422)
{
    alias U = Unqual!T;

    static if (is(U == JSONValue))
    {
        return value;
    }
    else static if (is(U == bool))
    {
        if (value.type == JSONType.true_)
            return true;
        if (value.type == JSONType.false_)
            return false;
        throw new HttpError(errorStatus,
            fieldError(fieldPath, "expected boolean, got " ~ jsonTypeName(value.type)));
    }
    else static if (is(U == enum))
    {
        if (value.type != JSONType.string)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "expected enum string, got " ~ jsonTypeName(value.type)));
        foreach (member; EnumMembers!U)
        {
            if (to!string(member) == value.str)
                return member;
        }
        throw new HttpError(errorStatus,
            fieldError(fieldPath, "invalid enum value '" ~ value.str ~ "'"));
    }
    else static if (isIntegral!U)
    {
        if (value.type == JSONType.integer)
        {
            const v = value.integer;
            static if (isUnsigned!U)
            {
                if (v < 0 || cast(ulong) v > U.max)
                    throw new HttpError(errorStatus, fieldError(fieldPath, "integer out of range"));
                return cast(U) v;
            }
            else
            {
                if (v < U.min || v > U.max)
                    throw new HttpError(errorStatus, fieldError(fieldPath, "integer out of range"));
                return cast(U) v;
            }
        }
        else if (value.type == JSONType.uinteger)
        {
            const v = value.uinteger;
            if (v > cast(ulong) U.max)
                throw new HttpError(errorStatus, fieldError(fieldPath, "integer out of range"));
            return cast(U) v;
        }
        throw new HttpError(errorStatus,
            fieldError(fieldPath, "expected integer, got " ~ jsonTypeName(value.type)));
    }
    else static if (isFloatingPoint!U)
    {
        if (value.type == JSONType.float_)
            return cast(U) value.floating;
        if (value.type == JSONType.integer)
            return cast(U) value.integer;
        if (value.type == JSONType.uinteger)
            return cast(U) value.uinteger;
        throw new HttpError(errorStatus,
            fieldError(fieldPath, "expected number, got " ~ jsonTypeName(value.type)));
    }
    else static if (isSomeChar!U)
    {
        if (value.type != JSONType.string || value.str.length == 0)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "expected non-empty character string"));
        return to!U(value.str[0 .. 1])[0];
    }
    else static if (isSomeString!U)
    {
        if (value.type != JSONType.string)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "expected string, got " ~ jsonTypeName(value.type)));
        static if (is(U == string))
            return value.str;
        else
            return to!U(value.str);
    }
    else static if (is(U == Nullable!V, V))
    {
        U result;
        if (value.type == JSONType.null_)
            return result;
        result = fromJSONValue!V(value, fieldPath, errorStatus);
        return result;
    }
    else static if (isStaticArray!U)
    {
        if (value.type != JSONType.array)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "expected array, got " ~ jsonTypeName(value.type)));
        alias Elem = typeof(U.init[0]);
        if (value.array.length != U.length)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, format("expected array of length %d, got %d",
                                             U.length, value.array.length)));
        U result;
        foreach (i, item; value.array)
            result[i] = fromJSONValue!Elem(item, format("%s[%d]", fieldPath, i), errorStatus);
        return result;
    }
    else static if (isDynamicArray!U)
    {
        if (value.type != JSONType.array)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "expected array, got " ~ jsonTypeName(value.type)));
        alias Elem = typeof(U.init[0]);
        Elem[] result;
        result.reserve(value.array.length);
        foreach (i, item; value.array)
            result ~= fromJSONValue!Elem(item, format("%s[%d]", fieldPath, i), errorStatus);
        return result;
    }
    else static if (isAssociativeArray!U)
    {
        if (value.type != JSONType.object)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "expected object, got " ~ jsonTypeName(value.type)));
        alias Key = KeyType!U;
        alias Val = ValueType!U;
        U result;
        foreach (k, item; value.object)
        {
            const childPath = fieldPath.length ? fieldPath ~ "." ~ k : k;
            try
                result[to!Key(k)] = fromJSONValue!Val(item, childPath, errorStatus);
            catch (ConvException e)
                throw new HttpError(errorStatus, fieldError(childPath, "invalid object key '" ~ k ~ "'"),
                                    __FILE__, __LINE__, e);
        }
        return result;
    }
    else static if (is(U == struct) || is(U == class))
    {
        static if (hasMember!(U, "fromJSON") &&
                   is(typeof(U.fromJSON(value)) : U))
        {
            return U.fromJSON(value);
        }
        else
        {
            if (value.type != JSONType.object)
                throw new HttpError(errorStatus,
                    fieldError(fieldPath, "expected object, got " ~ jsonTypeName(value.type)));

            static if (is(U == struct))
                U result = U.init;
            else
                U result = new U;

            alias fieldNames = FieldNameTuple!U;
            static assert(fieldNames.length == U.tupleof.length,
                          "Cannot reflect over fields of " ~ U.stringof);

            foreach (i, ref field; result.tupleof)
            {
                enum name = fieldNames[i];
                alias FieldType = typeof(field);
                const childPath = fieldPath.length ? fieldPath ~ "." ~ name : name;

                if (auto found = name in value.object)
                {
                    static if (is(Unqual!FieldType == Nullable!NV, NV))
                    {
                        field = fromJSONValue!(Unqual!FieldType)(*found, childPath, errorStatus);
                    }
                    else
                    {
                        if (found.type == JSONType.null_)
                        {
                            static if (hasUDA!(result.tupleof[i], optional) ||
                                       isFieldOptional!(U, i)())
                            {
                                // Preserve default value when optional/defaulted
                            }
                            else
                            {
                                throw new HttpError(errorStatus,
                                    "Missing required field: " ~ childPath);
                            }
                        }
                        else
                        {
                            field = fromJSONValue!(Unqual!FieldType)(*found, childPath, errorStatus);
                        }
                    }
                }
                else
                {
                    static if (is(Unqual!FieldType == Nullable!NV, NV) ||
                               hasUDA!(result.tupleof[i], optional) ||
                               isFieldOptional!(U, i)())
                    {
                        // Leave default/null value intact
                    }
                    else
                    {
                        throw new HttpError(errorStatus,
                            "Missing required field: " ~ childPath);
                    }
                }
            }
            return result;
        }
    }
    else
    {
        static assert(false, "Cannot deserialize " ~ T.stringof ~ " from JSON");
    }
}

/// Deserialize string-valued multi-maps (query strings or URL-encoded forms) into struct/class `T`.
T fromStringMap(T)(const string[][string] values, string prefix = "", ushort errorStatus = 400)
{
    alias U = Unqual!T;
    static assert(is(U == struct) || is(U == class),
                  "fromStringMap target must be a struct or class, not " ~ T.stringof);

    static if (is(U == struct))
        U result = U.init;
    else
        U result = new U;

    alias fieldNames = FieldNameTuple!U;
    foreach (i, ref field; result.tupleof)
    {
        enum name = fieldNames[i];
        alias FieldType = Unqual!(typeof(field));
        const key = prefix.length ? prefix ~ "." ~ name : name;

        static if ((is(FieldType == struct) || is(FieldType == class)) &&
                   !is(FieldType == Nullable!NV, NV) && !is(FieldType == JSONValue))
        {
            if (hasKeyPrefix(values, key))
            {
                field = fromStringMap!FieldType(values, key, errorStatus);
            }
            else static if (hasUDA!(result.tupleof[i], optional) || isFieldOptional!(U, i)())
            {
                // Keep default value
            }
            else
            {
                throw new HttpError(errorStatus, "Missing required field: " ~ key);
            }
        }
        else if (auto rawList = key in values)
        {
            static if (isDynamicArray!FieldType && !isSomeString!FieldType)
            {
                alias Elem = Unqual!(typeof(FieldType.init[0]));
                Elem[] arr;
                arr.reserve((*rawList).length);
                foreach (idx, item; *rawList)
                    arr ~= parseScalarFromString!Elem(item, format("%s[%d]", key, idx), errorStatus);
                field = arr;
            }
            else
            {
                const rawVal = (*rawList).length ? (*rawList)[$ - 1] : "";
                static if (is(FieldType == Nullable!NV, NV))
                {
                    if (rawVal.length == 0)
                        field = FieldType.init;
                    else
                        field = FieldType(parseScalarFromString!NV(rawVal, key, errorStatus));
                }
                else
                {
                    field = parseScalarFromString!FieldType(rawVal, key, errorStatus);
                }
            }
        }
        else
        {
            static if (is(FieldType == Nullable!NV, NV) ||
                       hasUDA!(result.tupleof[i], optional) ||
                       isFieldOptional!(U, i)())
            {
                // Keep default/null value
            }
            else
            {
                throw new HttpError(errorStatus, "Missing required field: " ~ key);
            }
        }
    }
    return result;
}

private bool hasKeyPrefix(const string[][string] values, string prefix)
{
    const dotPrefix = prefix ~ ".";
    foreach (k, _; values)
    {
        if (k.length > dotPrefix.length && k[0 .. dotPrefix.length] == dotPrefix)
            return true;
    }
    return false;
}

private T parseScalarFromString(T)(string raw, string fieldPath, ushort errorStatus)
{
    alias U = Unqual!T;
    static if (is(U == bool))
    {
        const low = raw.strip.toLower;
        if (low == "true" || low == "1" || low == "yes" || low == "on")
            return true;
        if (low == "false" || low == "0" || low == "no" || low == "off")
            return false;
        throw new HttpError(errorStatus,
            fieldError(fieldPath, "expected boolean, got '" ~ raw ~ "'"));
    }
    else static if (is(U == enum))
    {
        foreach (member; EnumMembers!U)
        {
            if (to!string(member) == raw)
                return member;
        }
        throw new HttpError(errorStatus,
            fieldError(fieldPath, "invalid enum value '" ~ raw ~ "'"));
    }
    else static if (isSomeString!U)
    {
        static if (is(U == string))
            return raw;
        else
            return to!U(raw);
    }
    else static if (isSomeChar!U)
    {
        if (raw.length == 0)
            throw new HttpError(errorStatus, fieldError(fieldPath, "expected character"));
        return to!U(raw[0 .. 1])[0];
    }
    else static if (isIntegral!U || isFloatingPoint!U)
    {
        try
            return to!U(raw.strip);
        catch (ConvException e)
            throw new HttpError(errorStatus,
                fieldError(fieldPath, "invalid number '" ~ raw ~ "'"),
                __FILE__, __LINE__, e);
    }
    else
    {
        static assert(false, "Cannot parse " ~ T.stringof ~ " from query/form string");
    }
}

private bool isFieldOptional(U, size_t idx)()
{
    static if (is(U == struct))
    {
        alias FT = typeof(U.init.tupleof[idx]);
        static if (isFloatingPoint!FT)
        {
            // NaN != NaN; check bit-level / isNaN difference from FT.init
            import std.math : isNaN;
            return !isNaN(U.init.tupleof[idx]);
        }
        else
        {
            return U.init.tupleof[idx] != FT.init;
        }
    }
    else
    {
        return false;
    }
}

private string fieldError(string path, string reason)
{
    return path.length ? format("Invalid field '%s': %s", path, reason) : reason;
}

private string jsonTypeName(JSONType t)
{
    final switch (t)
    {
        case JSONType.null_: return "null";
        case JSONType.string: return "string";
        case JSONType.integer: return "integer";
        case JSONType.uinteger: return "integer";
        case JSONType.float_: return "float";
        case JSONType.array: return "array";
        case JSONType.object: return "object";
        case JSONType.true_: return "boolean";
        case JSONType.false_: return "boolean";
    }
}

unittest
{
    import std.typecons : nullable;

    const JSONValue constJson = JSONValue(["a": 1]);
    assert(toJSONValue(constJson) == constJson);

    const Nullable!int empty;
    assert(toJSONValue(empty).isNull);
    assert(toJSONValue(nullable(3)).integer == 3);

    assert(toJSONValue('x').str == "x");
    assert(toJSONValue("hé"w).str == "hé");
    assert(toJSONValue(double.nan).isNull);

    static struct Point { int x; const int y; }
    const p = Point(1, 2);
    assert(toJSONValue(p)["y"].integer == 2);

    enum Role { admin, member }
    static struct Address { string city; @optional string zip; }
    static struct UserInput
    {
        string name;
        int age = 18;
        Role role = Role.member;
        Nullable!string bio;
        Address address;
    }

    auto parsed = fromJSONValue!UserInput(JSONValue([
        "name": JSONValue("Alice"),
        "address": JSONValue(["city": JSONValue("Vilnius")])
    ]));
    assert(parsed.name == "Alice");
    assert(parsed.age == 18);
    assert(parsed.role == Role.member);
    assert(parsed.bio.isNull);
    assert(parsed.address.city == "Vilnius");
    assert(parsed.address.zip is null);

    bool threwMissing = false;
    try
    {
        fromJSONValue!UserInput(JSONValue(["name": JSONValue("Bob")]));
    }
    catch (HttpError e)
    {
        threwMissing = e.status == 422;
    }
    assert(threwMissing);
}
