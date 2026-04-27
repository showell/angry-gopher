(function(scope){
'use strict';

function F(arity, fun, wrapper) {
  wrapper.a = arity;
  wrapper.f = fun;
  return wrapper;
}

function F2(fun) {
  return F(2, fun, function(a) { return function(b) { return fun(a,b); }; })
}
function F3(fun) {
  return F(3, fun, function(a) {
    return function(b) { return function(c) { return fun(a, b, c); }; };
  });
}
function F4(fun) {
  return F(4, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return fun(a, b, c, d); }; }; };
  });
}
function F5(fun) {
  return F(5, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return fun(a, b, c, d, e); }; }; }; };
  });
}
function F6(fun) {
  return F(6, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return fun(a, b, c, d, e, f); }; }; }; }; };
  });
}
function F7(fun) {
  return F(7, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return function(g) { return fun(a, b, c, d, e, f, g); }; }; }; }; }; };
  });
}
function F8(fun) {
  return F(8, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return function(g) { return function(h) {
    return fun(a, b, c, d, e, f, g, h); }; }; }; }; }; }; };
  });
}
function F9(fun) {
  return F(9, fun, function(a) { return function(b) { return function(c) {
    return function(d) { return function(e) { return function(f) {
    return function(g) { return function(h) { return function(i) {
    return fun(a, b, c, d, e, f, g, h, i); }; }; }; }; }; }; }; };
  });
}

function A2(fun, a, b) {
  return fun.a === 2 ? fun.f(a, b) : fun(a)(b);
}
function A3(fun, a, b, c) {
  return fun.a === 3 ? fun.f(a, b, c) : fun(a)(b)(c);
}
function A4(fun, a, b, c, d) {
  return fun.a === 4 ? fun.f(a, b, c, d) : fun(a)(b)(c)(d);
}
function A5(fun, a, b, c, d, e) {
  return fun.a === 5 ? fun.f(a, b, c, d, e) : fun(a)(b)(c)(d)(e);
}
function A6(fun, a, b, c, d, e, f) {
  return fun.a === 6 ? fun.f(a, b, c, d, e, f) : fun(a)(b)(c)(d)(e)(f);
}
function A7(fun, a, b, c, d, e, f, g) {
  return fun.a === 7 ? fun.f(a, b, c, d, e, f, g) : fun(a)(b)(c)(d)(e)(f)(g);
}
function A8(fun, a, b, c, d, e, f, g, h) {
  return fun.a === 8 ? fun.f(a, b, c, d, e, f, g, h) : fun(a)(b)(c)(d)(e)(f)(g)(h);
}
function A9(fun, a, b, c, d, e, f, g, h, i) {
  return fun.a === 9 ? fun.f(a, b, c, d, e, f, g, h, i) : fun(a)(b)(c)(d)(e)(f)(g)(h)(i);
}

console.warn('Compiled in DEV mode. Follow the advice at https://elm-lang.org/0.19.1/optimize for better performance and smaller assets.');


// EQUALITY

function _Utils_eq(x, y)
{
	for (
		var pair, stack = [], isEqual = _Utils_eqHelp(x, y, 0, stack);
		isEqual && (pair = stack.pop());
		isEqual = _Utils_eqHelp(pair.a, pair.b, 0, stack)
		)
	{}

	return isEqual;
}

function _Utils_eqHelp(x, y, depth, stack)
{
	if (x === y)
	{
		return true;
	}

	if (typeof x !== 'object' || x === null || y === null)
	{
		typeof x === 'function' && _Debug_crash(5);
		return false;
	}

	if (depth > 100)
	{
		stack.push(_Utils_Tuple2(x,y));
		return true;
	}

	/**/
	if (x.$ === 'Set_elm_builtin')
	{
		x = $elm$core$Set$toList(x);
		y = $elm$core$Set$toList(y);
	}
	if (x.$ === 'RBNode_elm_builtin' || x.$ === 'RBEmpty_elm_builtin')
	{
		x = $elm$core$Dict$toList(x);
		y = $elm$core$Dict$toList(y);
	}
	//*/

	/**_UNUSED/
	if (x.$ < 0)
	{
		x = $elm$core$Dict$toList(x);
		y = $elm$core$Dict$toList(y);
	}
	//*/

	for (var key in x)
	{
		if (!_Utils_eqHelp(x[key], y[key], depth + 1, stack))
		{
			return false;
		}
	}
	return true;
}

var _Utils_equal = F2(_Utils_eq);
var _Utils_notEqual = F2(function(a, b) { return !_Utils_eq(a,b); });



// COMPARISONS

// Code in Generate/JavaScript.hs, Basics.js, and List.js depends on
// the particular integer values assigned to LT, EQ, and GT.

function _Utils_cmp(x, y, ord)
{
	if (typeof x !== 'object')
	{
		return x === y ? /*EQ*/ 0 : x < y ? /*LT*/ -1 : /*GT*/ 1;
	}

	/**/
	if (x instanceof String)
	{
		var a = x.valueOf();
		var b = y.valueOf();
		return a === b ? 0 : a < b ? -1 : 1;
	}
	//*/

	/**_UNUSED/
	if (typeof x.$ === 'undefined')
	//*/
	/**/
	if (x.$[0] === '#')
	//*/
	{
		return (ord = _Utils_cmp(x.a, y.a))
			? ord
			: (ord = _Utils_cmp(x.b, y.b))
				? ord
				: _Utils_cmp(x.c, y.c);
	}

	// traverse conses until end of a list or a mismatch
	for (; x.b && y.b && !(ord = _Utils_cmp(x.a, y.a)); x = x.b, y = y.b) {} // WHILE_CONSES
	return ord || (x.b ? /*GT*/ 1 : y.b ? /*LT*/ -1 : /*EQ*/ 0);
}

var _Utils_lt = F2(function(a, b) { return _Utils_cmp(a, b) < 0; });
var _Utils_le = F2(function(a, b) { return _Utils_cmp(a, b) < 1; });
var _Utils_gt = F2(function(a, b) { return _Utils_cmp(a, b) > 0; });
var _Utils_ge = F2(function(a, b) { return _Utils_cmp(a, b) >= 0; });

var _Utils_compare = F2(function(x, y)
{
	var n = _Utils_cmp(x, y);
	return n < 0 ? $elm$core$Basics$LT : n ? $elm$core$Basics$GT : $elm$core$Basics$EQ;
});


// COMMON VALUES

var _Utils_Tuple0_UNUSED = 0;
var _Utils_Tuple0 = { $: '#0' };

function _Utils_Tuple2_UNUSED(a, b) { return { a: a, b: b }; }
function _Utils_Tuple2(a, b) { return { $: '#2', a: a, b: b }; }

function _Utils_Tuple3_UNUSED(a, b, c) { return { a: a, b: b, c: c }; }
function _Utils_Tuple3(a, b, c) { return { $: '#3', a: a, b: b, c: c }; }

function _Utils_chr_UNUSED(c) { return c; }
function _Utils_chr(c) { return new String(c); }


// RECORDS

function _Utils_update(oldRecord, updatedFields)
{
	var newRecord = {};

	for (var key in oldRecord)
	{
		newRecord[key] = oldRecord[key];
	}

	for (var key in updatedFields)
	{
		newRecord[key] = updatedFields[key];
	}

	return newRecord;
}


// APPEND

var _Utils_append = F2(_Utils_ap);

function _Utils_ap(xs, ys)
{
	// append Strings
	if (typeof xs === 'string')
	{
		return xs + ys;
	}

	// append Lists
	if (!xs.b)
	{
		return ys;
	}
	var root = _List_Cons(xs.a, ys);
	xs = xs.b
	for (var curr = root; xs.b; xs = xs.b) // WHILE_CONS
	{
		curr = curr.b = _List_Cons(xs.a, ys);
	}
	return root;
}



var _List_Nil_UNUSED = { $: 0 };
var _List_Nil = { $: '[]' };

function _List_Cons_UNUSED(hd, tl) { return { $: 1, a: hd, b: tl }; }
function _List_Cons(hd, tl) { return { $: '::', a: hd, b: tl }; }


var _List_cons = F2(_List_Cons);

function _List_fromArray(arr)
{
	var out = _List_Nil;
	for (var i = arr.length; i--; )
	{
		out = _List_Cons(arr[i], out);
	}
	return out;
}

function _List_toArray(xs)
{
	for (var out = []; xs.b; xs = xs.b) // WHILE_CONS
	{
		out.push(xs.a);
	}
	return out;
}

var _List_map2 = F3(function(f, xs, ys)
{
	for (var arr = []; xs.b && ys.b; xs = xs.b, ys = ys.b) // WHILE_CONSES
	{
		arr.push(A2(f, xs.a, ys.a));
	}
	return _List_fromArray(arr);
});

var _List_map3 = F4(function(f, xs, ys, zs)
{
	for (var arr = []; xs.b && ys.b && zs.b; xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
	{
		arr.push(A3(f, xs.a, ys.a, zs.a));
	}
	return _List_fromArray(arr);
});

var _List_map4 = F5(function(f, ws, xs, ys, zs)
{
	for (var arr = []; ws.b && xs.b && ys.b && zs.b; ws = ws.b, xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
	{
		arr.push(A4(f, ws.a, xs.a, ys.a, zs.a));
	}
	return _List_fromArray(arr);
});

var _List_map5 = F6(function(f, vs, ws, xs, ys, zs)
{
	for (var arr = []; vs.b && ws.b && xs.b && ys.b && zs.b; vs = vs.b, ws = ws.b, xs = xs.b, ys = ys.b, zs = zs.b) // WHILE_CONSES
	{
		arr.push(A5(f, vs.a, ws.a, xs.a, ys.a, zs.a));
	}
	return _List_fromArray(arr);
});

var _List_sortBy = F2(function(f, xs)
{
	return _List_fromArray(_List_toArray(xs).sort(function(a, b) {
		return _Utils_cmp(f(a), f(b));
	}));
});

var _List_sortWith = F2(function(f, xs)
{
	return _List_fromArray(_List_toArray(xs).sort(function(a, b) {
		var ord = A2(f, a, b);
		return ord === $elm$core$Basics$EQ ? 0 : ord === $elm$core$Basics$LT ? -1 : 1;
	}));
});



var _JsArray_empty = [];

function _JsArray_singleton(value)
{
    return [value];
}

function _JsArray_length(array)
{
    return array.length;
}

var _JsArray_initialize = F3(function(size, offset, func)
{
    var result = new Array(size);

    for (var i = 0; i < size; i++)
    {
        result[i] = func(offset + i);
    }

    return result;
});

var _JsArray_initializeFromList = F2(function (max, ls)
{
    var result = new Array(max);

    for (var i = 0; i < max && ls.b; i++)
    {
        result[i] = ls.a;
        ls = ls.b;
    }

    result.length = i;
    return _Utils_Tuple2(result, ls);
});

var _JsArray_unsafeGet = F2(function(index, array)
{
    return array[index];
});

var _JsArray_unsafeSet = F3(function(index, value, array)
{
    var length = array.length;
    var result = new Array(length);

    for (var i = 0; i < length; i++)
    {
        result[i] = array[i];
    }

    result[index] = value;
    return result;
});

var _JsArray_push = F2(function(value, array)
{
    var length = array.length;
    var result = new Array(length + 1);

    for (var i = 0; i < length; i++)
    {
        result[i] = array[i];
    }

    result[length] = value;
    return result;
});

var _JsArray_foldl = F3(function(func, acc, array)
{
    var length = array.length;

    for (var i = 0; i < length; i++)
    {
        acc = A2(func, array[i], acc);
    }

    return acc;
});

var _JsArray_foldr = F3(function(func, acc, array)
{
    for (var i = array.length - 1; i >= 0; i--)
    {
        acc = A2(func, array[i], acc);
    }

    return acc;
});

var _JsArray_map = F2(function(func, array)
{
    var length = array.length;
    var result = new Array(length);

    for (var i = 0; i < length; i++)
    {
        result[i] = func(array[i]);
    }

    return result;
});

var _JsArray_indexedMap = F3(function(func, offset, array)
{
    var length = array.length;
    var result = new Array(length);

    for (var i = 0; i < length; i++)
    {
        result[i] = A2(func, offset + i, array[i]);
    }

    return result;
});

var _JsArray_slice = F3(function(from, to, array)
{
    return array.slice(from, to);
});

var _JsArray_appendN = F3(function(n, dest, source)
{
    var destLen = dest.length;
    var itemsToCopy = n - destLen;

    if (itemsToCopy > source.length)
    {
        itemsToCopy = source.length;
    }

    var size = destLen + itemsToCopy;
    var result = new Array(size);

    for (var i = 0; i < destLen; i++)
    {
        result[i] = dest[i];
    }

    for (var i = 0; i < itemsToCopy; i++)
    {
        result[i + destLen] = source[i];
    }

    return result;
});



// LOG

var _Debug_log_UNUSED = F2(function(tag, value)
{
	return value;
});

var _Debug_log = F2(function(tag, value)
{
	console.log(tag + ': ' + _Debug_toString(value));
	return value;
});


// TODOS

function _Debug_todo(moduleName, region)
{
	return function(message) {
		_Debug_crash(8, moduleName, region, message);
	};
}

function _Debug_todoCase(moduleName, region, value)
{
	return function(message) {
		_Debug_crash(9, moduleName, region, value, message);
	};
}


// TO STRING

function _Debug_toString_UNUSED(value)
{
	return '<internals>';
}

function _Debug_toString(value)
{
	return _Debug_toAnsiString(false, value);
}

function _Debug_toAnsiString(ansi, value)
{
	if (typeof value === 'function')
	{
		return _Debug_internalColor(ansi, '<function>');
	}

	if (typeof value === 'boolean')
	{
		return _Debug_ctorColor(ansi, value ? 'True' : 'False');
	}

	if (typeof value === 'number')
	{
		return _Debug_numberColor(ansi, value + '');
	}

	if (value instanceof String)
	{
		return _Debug_charColor(ansi, "'" + _Debug_addSlashes(value, true) + "'");
	}

	if (typeof value === 'string')
	{
		return _Debug_stringColor(ansi, '"' + _Debug_addSlashes(value, false) + '"');
	}

	if (typeof value === 'object' && '$' in value)
	{
		var tag = value.$;

		if (typeof tag === 'number')
		{
			return _Debug_internalColor(ansi, '<internals>');
		}

		if (tag[0] === '#')
		{
			var output = [];
			for (var k in value)
			{
				if (k === '$') continue;
				output.push(_Debug_toAnsiString(ansi, value[k]));
			}
			return '(' + output.join(',') + ')';
		}

		if (tag === 'Set_elm_builtin')
		{
			return _Debug_ctorColor(ansi, 'Set')
				+ _Debug_fadeColor(ansi, '.fromList') + ' '
				+ _Debug_toAnsiString(ansi, $elm$core$Set$toList(value));
		}

		if (tag === 'RBNode_elm_builtin' || tag === 'RBEmpty_elm_builtin')
		{
			return _Debug_ctorColor(ansi, 'Dict')
				+ _Debug_fadeColor(ansi, '.fromList') + ' '
				+ _Debug_toAnsiString(ansi, $elm$core$Dict$toList(value));
		}

		if (tag === 'Array_elm_builtin')
		{
			return _Debug_ctorColor(ansi, 'Array')
				+ _Debug_fadeColor(ansi, '.fromList') + ' '
				+ _Debug_toAnsiString(ansi, $elm$core$Array$toList(value));
		}

		if (tag === '::' || tag === '[]')
		{
			var output = '[';

			value.b && (output += _Debug_toAnsiString(ansi, value.a), value = value.b)

			for (; value.b; value = value.b) // WHILE_CONS
			{
				output += ',' + _Debug_toAnsiString(ansi, value.a);
			}
			return output + ']';
		}

		var output = '';
		for (var i in value)
		{
			if (i === '$') continue;
			var str = _Debug_toAnsiString(ansi, value[i]);
			var c0 = str[0];
			var parenless = c0 === '{' || c0 === '(' || c0 === '[' || c0 === '<' || c0 === '"' || str.indexOf(' ') < 0;
			output += ' ' + (parenless ? str : '(' + str + ')');
		}
		return _Debug_ctorColor(ansi, tag) + output;
	}

	if (typeof DataView === 'function' && value instanceof DataView)
	{
		return _Debug_stringColor(ansi, '<' + value.byteLength + ' bytes>');
	}

	if (typeof File !== 'undefined' && value instanceof File)
	{
		return _Debug_internalColor(ansi, '<' + value.name + '>');
	}

	if (typeof value === 'object')
	{
		var output = [];
		for (var key in value)
		{
			var field = key[0] === '_' ? key.slice(1) : key;
			output.push(_Debug_fadeColor(ansi, field) + ' = ' + _Debug_toAnsiString(ansi, value[key]));
		}
		if (output.length === 0)
		{
			return '{}';
		}
		return '{ ' + output.join(', ') + ' }';
	}

	return _Debug_internalColor(ansi, '<internals>');
}

function _Debug_addSlashes(str, isChar)
{
	var s = str
		.replace(/\\/g, '\\\\')
		.replace(/\n/g, '\\n')
		.replace(/\t/g, '\\t')
		.replace(/\r/g, '\\r')
		.replace(/\v/g, '\\v')
		.replace(/\0/g, '\\0');

	if (isChar)
	{
		return s.replace(/\'/g, '\\\'');
	}
	else
	{
		return s.replace(/\"/g, '\\"');
	}
}

function _Debug_ctorColor(ansi, string)
{
	return ansi ? '\x1b[96m' + string + '\x1b[0m' : string;
}

function _Debug_numberColor(ansi, string)
{
	return ansi ? '\x1b[95m' + string + '\x1b[0m' : string;
}

function _Debug_stringColor(ansi, string)
{
	return ansi ? '\x1b[93m' + string + '\x1b[0m' : string;
}

function _Debug_charColor(ansi, string)
{
	return ansi ? '\x1b[92m' + string + '\x1b[0m' : string;
}

function _Debug_fadeColor(ansi, string)
{
	return ansi ? '\x1b[37m' + string + '\x1b[0m' : string;
}

function _Debug_internalColor(ansi, string)
{
	return ansi ? '\x1b[36m' + string + '\x1b[0m' : string;
}

function _Debug_toHexDigit(n)
{
	return String.fromCharCode(n < 10 ? 48 + n : 55 + n);
}


// CRASH


function _Debug_crash_UNUSED(identifier)
{
	throw new Error('https://github.com/elm/core/blob/1.0.0/hints/' + identifier + '.md');
}


function _Debug_crash(identifier, fact1, fact2, fact3, fact4)
{
	switch(identifier)
	{
		case 0:
			throw new Error('What node should I take over? In JavaScript I need something like:\n\n    Elm.Main.init({\n        node: document.getElementById("elm-node")\n    })\n\nYou need to do this with any Browser.sandbox or Browser.element program.');

		case 1:
			throw new Error('Browser.application programs cannot handle URLs like this:\n\n    ' + document.location.href + '\n\nWhat is the root? The root of your file system? Try looking at this program with `elm reactor` or some other server.');

		case 2:
			var jsonErrorString = fact1;
			throw new Error('Problem with the flags given to your Elm program on initialization.\n\n' + jsonErrorString);

		case 3:
			var portName = fact1;
			throw new Error('There can only be one port named `' + portName + '`, but your program has multiple.');

		case 4:
			var portName = fact1;
			var problem = fact2;
			throw new Error('Trying to send an unexpected type of value through port `' + portName + '`:\n' + problem);

		case 5:
			throw new Error('Trying to use `(==)` on functions.\nThere is no way to know if functions are "the same" in the Elm sense.\nRead more about this at https://package.elm-lang.org/packages/elm/core/latest/Basics#== which describes why it is this way and what the better version will look like.');

		case 6:
			var moduleName = fact1;
			throw new Error('Your page is loading multiple Elm scripts with a module named ' + moduleName + '. Maybe a duplicate script is getting loaded accidentally? If not, rename one of them so I know which is which!');

		case 8:
			var moduleName = fact1;
			var region = fact2;
			var message = fact3;
			throw new Error('TODO in module `' + moduleName + '` ' + _Debug_regionToString(region) + '\n\n' + message);

		case 9:
			var moduleName = fact1;
			var region = fact2;
			var value = fact3;
			var message = fact4;
			throw new Error(
				'TODO in module `' + moduleName + '` from the `case` expression '
				+ _Debug_regionToString(region) + '\n\nIt received the following value:\n\n    '
				+ _Debug_toString(value).replace('\n', '\n    ')
				+ '\n\nBut the branch that handles it says:\n\n    ' + message.replace('\n', '\n    ')
			);

		case 10:
			throw new Error('Bug in https://github.com/elm/virtual-dom/issues');

		case 11:
			throw new Error('Cannot perform mod 0. Division by zero error.');
	}
}

function _Debug_regionToString(region)
{
	if (region.start.line === region.end.line)
	{
		return 'on line ' + region.start.line;
	}
	return 'on lines ' + region.start.line + ' through ' + region.end.line;
}



// MATH

var _Basics_add = F2(function(a, b) { return a + b; });
var _Basics_sub = F2(function(a, b) { return a - b; });
var _Basics_mul = F2(function(a, b) { return a * b; });
var _Basics_fdiv = F2(function(a, b) { return a / b; });
var _Basics_idiv = F2(function(a, b) { return (a / b) | 0; });
var _Basics_pow = F2(Math.pow);

var _Basics_remainderBy = F2(function(b, a) { return a % b; });

// https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/divmodnote-letter.pdf
var _Basics_modBy = F2(function(modulus, x)
{
	var answer = x % modulus;
	return modulus === 0
		? _Debug_crash(11)
		:
	((answer > 0 && modulus < 0) || (answer < 0 && modulus > 0))
		? answer + modulus
		: answer;
});


// TRIGONOMETRY

var _Basics_pi = Math.PI;
var _Basics_e = Math.E;
var _Basics_cos = Math.cos;
var _Basics_sin = Math.sin;
var _Basics_tan = Math.tan;
var _Basics_acos = Math.acos;
var _Basics_asin = Math.asin;
var _Basics_atan = Math.atan;
var _Basics_atan2 = F2(Math.atan2);


// MORE MATH

function _Basics_toFloat(x) { return x; }
function _Basics_truncate(n) { return n | 0; }
function _Basics_isInfinite(n) { return n === Infinity || n === -Infinity; }

var _Basics_ceiling = Math.ceil;
var _Basics_floor = Math.floor;
var _Basics_round = Math.round;
var _Basics_sqrt = Math.sqrt;
var _Basics_log = Math.log;
var _Basics_isNaN = isNaN;


// BOOLEANS

function _Basics_not(bool) { return !bool; }
var _Basics_and = F2(function(a, b) { return a && b; });
var _Basics_or  = F2(function(a, b) { return a || b; });
var _Basics_xor = F2(function(a, b) { return a !== b; });



var _String_cons = F2(function(chr, str)
{
	return chr + str;
});

function _String_uncons(string)
{
	var word = string.charCodeAt(0);
	return !isNaN(word)
		? $elm$core$Maybe$Just(
			0xD800 <= word && word <= 0xDBFF
				? _Utils_Tuple2(_Utils_chr(string[0] + string[1]), string.slice(2))
				: _Utils_Tuple2(_Utils_chr(string[0]), string.slice(1))
		)
		: $elm$core$Maybe$Nothing;
}

var _String_append = F2(function(a, b)
{
	return a + b;
});

function _String_length(str)
{
	return str.length;
}

var _String_map = F2(function(func, string)
{
	var len = string.length;
	var array = new Array(len);
	var i = 0;
	while (i < len)
	{
		var word = string.charCodeAt(i);
		if (0xD800 <= word && word <= 0xDBFF)
		{
			array[i] = func(_Utils_chr(string[i] + string[i+1]));
			i += 2;
			continue;
		}
		array[i] = func(_Utils_chr(string[i]));
		i++;
	}
	return array.join('');
});

var _String_filter = F2(function(isGood, str)
{
	var arr = [];
	var len = str.length;
	var i = 0;
	while (i < len)
	{
		var char = str[i];
		var word = str.charCodeAt(i);
		i++;
		if (0xD800 <= word && word <= 0xDBFF)
		{
			char += str[i];
			i++;
		}

		if (isGood(_Utils_chr(char)))
		{
			arr.push(char);
		}
	}
	return arr.join('');
});

function _String_reverse(str)
{
	var len = str.length;
	var arr = new Array(len);
	var i = 0;
	while (i < len)
	{
		var word = str.charCodeAt(i);
		if (0xD800 <= word && word <= 0xDBFF)
		{
			arr[len - i] = str[i + 1];
			i++;
			arr[len - i] = str[i - 1];
			i++;
		}
		else
		{
			arr[len - i] = str[i];
			i++;
		}
	}
	return arr.join('');
}

var _String_foldl = F3(function(func, state, string)
{
	var len = string.length;
	var i = 0;
	while (i < len)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		i++;
		if (0xD800 <= word && word <= 0xDBFF)
		{
			char += string[i];
			i++;
		}
		state = A2(func, _Utils_chr(char), state);
	}
	return state;
});

var _String_foldr = F3(function(func, state, string)
{
	var i = string.length;
	while (i--)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		if (0xDC00 <= word && word <= 0xDFFF)
		{
			i--;
			char = string[i] + char;
		}
		state = A2(func, _Utils_chr(char), state);
	}
	return state;
});

var _String_split = F2(function(sep, str)
{
	return str.split(sep);
});

var _String_join = F2(function(sep, strs)
{
	return strs.join(sep);
});

var _String_slice = F3(function(start, end, str) {
	return str.slice(start, end);
});

function _String_trim(str)
{
	return str.trim();
}

function _String_trimLeft(str)
{
	return str.replace(/^\s+/, '');
}

function _String_trimRight(str)
{
	return str.replace(/\s+$/, '');
}

function _String_words(str)
{
	return _List_fromArray(str.trim().split(/\s+/g));
}

function _String_lines(str)
{
	return _List_fromArray(str.split(/\r\n|\r|\n/g));
}

function _String_toUpper(str)
{
	return str.toUpperCase();
}

function _String_toLower(str)
{
	return str.toLowerCase();
}

var _String_any = F2(function(isGood, string)
{
	var i = string.length;
	while (i--)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		if (0xDC00 <= word && word <= 0xDFFF)
		{
			i--;
			char = string[i] + char;
		}
		if (isGood(_Utils_chr(char)))
		{
			return true;
		}
	}
	return false;
});

var _String_all = F2(function(isGood, string)
{
	var i = string.length;
	while (i--)
	{
		var char = string[i];
		var word = string.charCodeAt(i);
		if (0xDC00 <= word && word <= 0xDFFF)
		{
			i--;
			char = string[i] + char;
		}
		if (!isGood(_Utils_chr(char)))
		{
			return false;
		}
	}
	return true;
});

var _String_contains = F2(function(sub, str)
{
	return str.indexOf(sub) > -1;
});

var _String_startsWith = F2(function(sub, str)
{
	return str.indexOf(sub) === 0;
});

var _String_endsWith = F2(function(sub, str)
{
	return str.length >= sub.length &&
		str.lastIndexOf(sub) === str.length - sub.length;
});

var _String_indexes = F2(function(sub, str)
{
	var subLen = sub.length;

	if (subLen < 1)
	{
		return _List_Nil;
	}

	var i = 0;
	var is = [];

	while ((i = str.indexOf(sub, i)) > -1)
	{
		is.push(i);
		i = i + subLen;
	}

	return _List_fromArray(is);
});


// TO STRING

function _String_fromNumber(number)
{
	return number + '';
}


// INT CONVERSIONS

function _String_toInt(str)
{
	var total = 0;
	var code0 = str.charCodeAt(0);
	var start = code0 == 0x2B /* + */ || code0 == 0x2D /* - */ ? 1 : 0;

	for (var i = start; i < str.length; ++i)
	{
		var code = str.charCodeAt(i);
		if (code < 0x30 || 0x39 < code)
		{
			return $elm$core$Maybe$Nothing;
		}
		total = 10 * total + code - 0x30;
	}

	return i == start
		? $elm$core$Maybe$Nothing
		: $elm$core$Maybe$Just(code0 == 0x2D ? -total : total);
}


// FLOAT CONVERSIONS

function _String_toFloat(s)
{
	// check if it is a hex, octal, or binary number
	if (s.length === 0 || /[\sxbo]/.test(s))
	{
		return $elm$core$Maybe$Nothing;
	}
	var n = +s;
	// faster isNaN check
	return n === n ? $elm$core$Maybe$Just(n) : $elm$core$Maybe$Nothing;
}

function _String_fromList(chars)
{
	return _List_toArray(chars).join('');
}




function _Char_toCode(char)
{
	var code = char.charCodeAt(0);
	if (0xD800 <= code && code <= 0xDBFF)
	{
		return (code - 0xD800) * 0x400 + char.charCodeAt(1) - 0xDC00 + 0x10000
	}
	return code;
}

function _Char_fromCode(code)
{
	return _Utils_chr(
		(code < 0 || 0x10FFFF < code)
			? '\uFFFD'
			:
		(code <= 0xFFFF)
			? String.fromCharCode(code)
			:
		(code -= 0x10000,
			String.fromCharCode(Math.floor(code / 0x400) + 0xD800, code % 0x400 + 0xDC00)
		)
	);
}

function _Char_toUpper(char)
{
	return _Utils_chr(char.toUpperCase());
}

function _Char_toLower(char)
{
	return _Utils_chr(char.toLowerCase());
}

function _Char_toLocaleUpper(char)
{
	return _Utils_chr(char.toLocaleUpperCase());
}

function _Char_toLocaleLower(char)
{
	return _Utils_chr(char.toLocaleLowerCase());
}



/**/
function _Json_errorToString(error)
{
	return $elm$json$Json$Decode$errorToString(error);
}
//*/


// CORE DECODERS

function _Json_succeed(msg)
{
	return {
		$: 0,
		a: msg
	};
}

function _Json_fail(msg)
{
	return {
		$: 1,
		a: msg
	};
}

function _Json_decodePrim(decoder)
{
	return { $: 2, b: decoder };
}

var _Json_decodeInt = _Json_decodePrim(function(value) {
	return (typeof value !== 'number')
		? _Json_expecting('an INT', value)
		:
	(-2147483647 < value && value < 2147483647 && (value | 0) === value)
		? $elm$core$Result$Ok(value)
		:
	(isFinite(value) && !(value % 1))
		? $elm$core$Result$Ok(value)
		: _Json_expecting('an INT', value);
});

var _Json_decodeBool = _Json_decodePrim(function(value) {
	return (typeof value === 'boolean')
		? $elm$core$Result$Ok(value)
		: _Json_expecting('a BOOL', value);
});

var _Json_decodeFloat = _Json_decodePrim(function(value) {
	return (typeof value === 'number')
		? $elm$core$Result$Ok(value)
		: _Json_expecting('a FLOAT', value);
});

var _Json_decodeValue = _Json_decodePrim(function(value) {
	return $elm$core$Result$Ok(_Json_wrap(value));
});

var _Json_decodeString = _Json_decodePrim(function(value) {
	return (typeof value === 'string')
		? $elm$core$Result$Ok(value)
		: (value instanceof String)
			? $elm$core$Result$Ok(value + '')
			: _Json_expecting('a STRING', value);
});

function _Json_decodeList(decoder) { return { $: 3, b: decoder }; }
function _Json_decodeArray(decoder) { return { $: 4, b: decoder }; }

function _Json_decodeNull(value) { return { $: 5, c: value }; }

var _Json_decodeField = F2(function(field, decoder)
{
	return {
		$: 6,
		d: field,
		b: decoder
	};
});

var _Json_decodeIndex = F2(function(index, decoder)
{
	return {
		$: 7,
		e: index,
		b: decoder
	};
});

function _Json_decodeKeyValuePairs(decoder)
{
	return {
		$: 8,
		b: decoder
	};
}

function _Json_mapMany(f, decoders)
{
	return {
		$: 9,
		f: f,
		g: decoders
	};
}

var _Json_andThen = F2(function(callback, decoder)
{
	return {
		$: 10,
		b: decoder,
		h: callback
	};
});

function _Json_oneOf(decoders)
{
	return {
		$: 11,
		g: decoders
	};
}


// DECODING OBJECTS

var _Json_map1 = F2(function(f, d1)
{
	return _Json_mapMany(f, [d1]);
});

var _Json_map2 = F3(function(f, d1, d2)
{
	return _Json_mapMany(f, [d1, d2]);
});

var _Json_map3 = F4(function(f, d1, d2, d3)
{
	return _Json_mapMany(f, [d1, d2, d3]);
});

var _Json_map4 = F5(function(f, d1, d2, d3, d4)
{
	return _Json_mapMany(f, [d1, d2, d3, d4]);
});

var _Json_map5 = F6(function(f, d1, d2, d3, d4, d5)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5]);
});

var _Json_map6 = F7(function(f, d1, d2, d3, d4, d5, d6)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5, d6]);
});

var _Json_map7 = F8(function(f, d1, d2, d3, d4, d5, d6, d7)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5, d6, d7]);
});

var _Json_map8 = F9(function(f, d1, d2, d3, d4, d5, d6, d7, d8)
{
	return _Json_mapMany(f, [d1, d2, d3, d4, d5, d6, d7, d8]);
});


// DECODE

var _Json_runOnString = F2(function(decoder, string)
{
	try
	{
		var value = JSON.parse(string);
		return _Json_runHelp(decoder, value);
	}
	catch (e)
	{
		return $elm$core$Result$Err(A2($elm$json$Json$Decode$Failure, 'This is not valid JSON! ' + e.message, _Json_wrap(string)));
	}
});

var _Json_run = F2(function(decoder, value)
{
	return _Json_runHelp(decoder, _Json_unwrap(value));
});

function _Json_runHelp(decoder, value)
{
	switch (decoder.$)
	{
		case 2:
			return decoder.b(value);

		case 5:
			return (value === null)
				? $elm$core$Result$Ok(decoder.c)
				: _Json_expecting('null', value);

		case 3:
			if (!_Json_isArray(value))
			{
				return _Json_expecting('a LIST', value);
			}
			return _Json_runArrayDecoder(decoder.b, value, _List_fromArray);

		case 4:
			if (!_Json_isArray(value))
			{
				return _Json_expecting('an ARRAY', value);
			}
			return _Json_runArrayDecoder(decoder.b, value, _Json_toElmArray);

		case 6:
			var field = decoder.d;
			if (typeof value !== 'object' || value === null || !(field in value))
			{
				return _Json_expecting('an OBJECT with a field named `' + field + '`', value);
			}
			var result = _Json_runHelp(decoder.b, value[field]);
			return ($elm$core$Result$isOk(result)) ? result : $elm$core$Result$Err(A2($elm$json$Json$Decode$Field, field, result.a));

		case 7:
			var index = decoder.e;
			if (!_Json_isArray(value))
			{
				return _Json_expecting('an ARRAY', value);
			}
			if (index >= value.length)
			{
				return _Json_expecting('a LONGER array. Need index ' + index + ' but only see ' + value.length + ' entries', value);
			}
			var result = _Json_runHelp(decoder.b, value[index]);
			return ($elm$core$Result$isOk(result)) ? result : $elm$core$Result$Err(A2($elm$json$Json$Decode$Index, index, result.a));

		case 8:
			if (typeof value !== 'object' || value === null || _Json_isArray(value))
			{
				return _Json_expecting('an OBJECT', value);
			}

			var keyValuePairs = _List_Nil;
			// TODO test perf of Object.keys and switch when support is good enough
			for (var key in value)
			{
				if (Object.prototype.hasOwnProperty.call(value, key))
				{
					var result = _Json_runHelp(decoder.b, value[key]);
					if (!$elm$core$Result$isOk(result))
					{
						return $elm$core$Result$Err(A2($elm$json$Json$Decode$Field, key, result.a));
					}
					keyValuePairs = _List_Cons(_Utils_Tuple2(key, result.a), keyValuePairs);
				}
			}
			return $elm$core$Result$Ok($elm$core$List$reverse(keyValuePairs));

		case 9:
			var answer = decoder.f;
			var decoders = decoder.g;
			for (var i = 0; i < decoders.length; i++)
			{
				var result = _Json_runHelp(decoders[i], value);
				if (!$elm$core$Result$isOk(result))
				{
					return result;
				}
				answer = answer(result.a);
			}
			return $elm$core$Result$Ok(answer);

		case 10:
			var result = _Json_runHelp(decoder.b, value);
			return (!$elm$core$Result$isOk(result))
				? result
				: _Json_runHelp(decoder.h(result.a), value);

		case 11:
			var errors = _List_Nil;
			for (var temp = decoder.g; temp.b; temp = temp.b) // WHILE_CONS
			{
				var result = _Json_runHelp(temp.a, value);
				if ($elm$core$Result$isOk(result))
				{
					return result;
				}
				errors = _List_Cons(result.a, errors);
			}
			return $elm$core$Result$Err($elm$json$Json$Decode$OneOf($elm$core$List$reverse(errors)));

		case 1:
			return $elm$core$Result$Err(A2($elm$json$Json$Decode$Failure, decoder.a, _Json_wrap(value)));

		case 0:
			return $elm$core$Result$Ok(decoder.a);
	}
}

function _Json_runArrayDecoder(decoder, value, toElmValue)
{
	var len = value.length;
	var array = new Array(len);
	for (var i = 0; i < len; i++)
	{
		var result = _Json_runHelp(decoder, value[i]);
		if (!$elm$core$Result$isOk(result))
		{
			return $elm$core$Result$Err(A2($elm$json$Json$Decode$Index, i, result.a));
		}
		array[i] = result.a;
	}
	return $elm$core$Result$Ok(toElmValue(array));
}

function _Json_isArray(value)
{
	return Array.isArray(value) || (typeof FileList !== 'undefined' && value instanceof FileList);
}

function _Json_toElmArray(array)
{
	return A2($elm$core$Array$initialize, array.length, function(i) { return array[i]; });
}

function _Json_expecting(type, value)
{
	return $elm$core$Result$Err(A2($elm$json$Json$Decode$Failure, 'Expecting ' + type, _Json_wrap(value)));
}


// EQUALITY

function _Json_equality(x, y)
{
	if (x === y)
	{
		return true;
	}

	if (x.$ !== y.$)
	{
		return false;
	}

	switch (x.$)
	{
		case 0:
		case 1:
			return x.a === y.a;

		case 2:
			return x.b === y.b;

		case 5:
			return x.c === y.c;

		case 3:
		case 4:
		case 8:
			return _Json_equality(x.b, y.b);

		case 6:
			return x.d === y.d && _Json_equality(x.b, y.b);

		case 7:
			return x.e === y.e && _Json_equality(x.b, y.b);

		case 9:
			return x.f === y.f && _Json_listEquality(x.g, y.g);

		case 10:
			return x.h === y.h && _Json_equality(x.b, y.b);

		case 11:
			return _Json_listEquality(x.g, y.g);
	}
}

function _Json_listEquality(aDecoders, bDecoders)
{
	var len = aDecoders.length;
	if (len !== bDecoders.length)
	{
		return false;
	}
	for (var i = 0; i < len; i++)
	{
		if (!_Json_equality(aDecoders[i], bDecoders[i]))
		{
			return false;
		}
	}
	return true;
}


// ENCODE

var _Json_encode = F2(function(indentLevel, value)
{
	return JSON.stringify(_Json_unwrap(value), null, indentLevel) + '';
});

function _Json_wrap(value) { return { $: 0, a: value }; }
function _Json_unwrap(value) { return value.a; }

function _Json_wrap_UNUSED(value) { return value; }
function _Json_unwrap_UNUSED(value) { return value; }

function _Json_emptyArray() { return []; }
function _Json_emptyObject() { return {}; }

var _Json_addField = F3(function(key, value, object)
{
	var unwrapped = _Json_unwrap(value);
	if (!(key === 'toJSON' && typeof unwrapped === 'function'))
	{
		object[key] = unwrapped;
	}
	return object;
});

function _Json_addEntry(func)
{
	return F2(function(entry, array)
	{
		array.push(_Json_unwrap(func(entry)));
		return array;
	});
}

var _Json_encodeNull = _Json_wrap(null);



// TASKS

function _Scheduler_succeed(value)
{
	return {
		$: 0,
		a: value
	};
}

function _Scheduler_fail(error)
{
	return {
		$: 1,
		a: error
	};
}

function _Scheduler_binding(callback)
{
	return {
		$: 2,
		b: callback,
		c: null
	};
}

var _Scheduler_andThen = F2(function(callback, task)
{
	return {
		$: 3,
		b: callback,
		d: task
	};
});

var _Scheduler_onError = F2(function(callback, task)
{
	return {
		$: 4,
		b: callback,
		d: task
	};
});

function _Scheduler_receive(callback)
{
	return {
		$: 5,
		b: callback
	};
}


// PROCESSES

var _Scheduler_guid = 0;

function _Scheduler_rawSpawn(task)
{
	var proc = {
		$: 0,
		e: _Scheduler_guid++,
		f: task,
		g: null,
		h: []
	};

	_Scheduler_enqueue(proc);

	return proc;
}

function _Scheduler_spawn(task)
{
	return _Scheduler_binding(function(callback) {
		callback(_Scheduler_succeed(_Scheduler_rawSpawn(task)));
	});
}

function _Scheduler_rawSend(proc, msg)
{
	proc.h.push(msg);
	_Scheduler_enqueue(proc);
}

var _Scheduler_send = F2(function(proc, msg)
{
	return _Scheduler_binding(function(callback) {
		_Scheduler_rawSend(proc, msg);
		callback(_Scheduler_succeed(_Utils_Tuple0));
	});
});

function _Scheduler_kill(proc)
{
	return _Scheduler_binding(function(callback) {
		var task = proc.f;
		if (task.$ === 2 && task.c)
		{
			task.c();
		}

		proc.f = null;

		callback(_Scheduler_succeed(_Utils_Tuple0));
	});
}


/* STEP PROCESSES

type alias Process =
  { $ : tag
  , id : unique_id
  , root : Task
  , stack : null | { $: SUCCEED | FAIL, a: callback, b: stack }
  , mailbox : [msg]
  }

*/


var _Scheduler_working = false;
var _Scheduler_queue = [];


function _Scheduler_enqueue(proc)
{
	_Scheduler_queue.push(proc);
	if (_Scheduler_working)
	{
		return;
	}
	_Scheduler_working = true;
	while (proc = _Scheduler_queue.shift())
	{
		_Scheduler_step(proc);
	}
	_Scheduler_working = false;
}


function _Scheduler_step(proc)
{
	while (proc.f)
	{
		var rootTag = proc.f.$;
		if (rootTag === 0 || rootTag === 1)
		{
			while (proc.g && proc.g.$ !== rootTag)
			{
				proc.g = proc.g.i;
			}
			if (!proc.g)
			{
				return;
			}
			proc.f = proc.g.b(proc.f.a);
			proc.g = proc.g.i;
		}
		else if (rootTag === 2)
		{
			proc.f.c = proc.f.b(function(newRoot) {
				proc.f = newRoot;
				_Scheduler_enqueue(proc);
			});
			return;
		}
		else if (rootTag === 5)
		{
			if (proc.h.length === 0)
			{
				return;
			}
			proc.f = proc.f.b(proc.h.shift());
		}
		else // if (rootTag === 3 || rootTag === 4)
		{
			proc.g = {
				$: rootTag === 3 ? 0 : 1,
				b: proc.f.b,
				i: proc.g
			};
			proc.f = proc.f.d;
		}
	}
}



function _Process_sleep(time)
{
	return _Scheduler_binding(function(callback) {
		var id = setTimeout(function() {
			callback(_Scheduler_succeed(_Utils_Tuple0));
		}, time);

		return function() { clearTimeout(id); };
	});
}




// PROGRAMS


var _Platform_worker = F4(function(impl, flagDecoder, debugMetadata, args)
{
	return _Platform_initialize(
		flagDecoder,
		args,
		impl.init,
		impl.update,
		impl.subscriptions,
		function() { return function() {} }
	);
});



// INITIALIZE A PROGRAM


function _Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder)
{
	var result = A2(_Json_run, flagDecoder, _Json_wrap(args ? args['flags'] : undefined));
	$elm$core$Result$isOk(result) || _Debug_crash(2 /**/, _Json_errorToString(result.a) /**/);
	var managers = {};
	var initPair = init(result.a);
	var model = initPair.a;
	var stepper = stepperBuilder(sendToApp, model);
	var ports = _Platform_setupEffects(managers, sendToApp);

	function sendToApp(msg, viewMetadata)
	{
		var pair = A2(update, msg, model);
		stepper(model = pair.a, viewMetadata);
		_Platform_enqueueEffects(managers, pair.b, subscriptions(model));
	}

	_Platform_enqueueEffects(managers, initPair.b, subscriptions(model));

	return ports ? { ports: ports } : {};
}



// TRACK PRELOADS
//
// This is used by code in elm/browser and elm/http
// to register any HTTP requests that are triggered by init.
//


var _Platform_preload;


function _Platform_registerPreload(url)
{
	_Platform_preload.add(url);
}



// EFFECT MANAGERS


var _Platform_effectManagers = {};


function _Platform_setupEffects(managers, sendToApp)
{
	var ports;

	// setup all necessary effect managers
	for (var key in _Platform_effectManagers)
	{
		var manager = _Platform_effectManagers[key];

		if (manager.a)
		{
			ports = ports || {};
			ports[key] = manager.a(key, sendToApp);
		}

		managers[key] = _Platform_instantiateManager(manager, sendToApp);
	}

	return ports;
}


function _Platform_createManager(init, onEffects, onSelfMsg, cmdMap, subMap)
{
	return {
		b: init,
		c: onEffects,
		d: onSelfMsg,
		e: cmdMap,
		f: subMap
	};
}


function _Platform_instantiateManager(info, sendToApp)
{
	var router = {
		g: sendToApp,
		h: undefined
	};

	var onEffects = info.c;
	var onSelfMsg = info.d;
	var cmdMap = info.e;
	var subMap = info.f;

	function loop(state)
	{
		return A2(_Scheduler_andThen, loop, _Scheduler_receive(function(msg)
		{
			var value = msg.a;

			if (msg.$ === 0)
			{
				return A3(onSelfMsg, router, value, state);
			}

			return cmdMap && subMap
				? A4(onEffects, router, value.i, value.j, state)
				: A3(onEffects, router, cmdMap ? value.i : value.j, state);
		}));
	}

	return router.h = _Scheduler_rawSpawn(A2(_Scheduler_andThen, loop, info.b));
}



// ROUTING


var _Platform_sendToApp = F2(function(router, msg)
{
	return _Scheduler_binding(function(callback)
	{
		router.g(msg);
		callback(_Scheduler_succeed(_Utils_Tuple0));
	});
});


var _Platform_sendToSelf = F2(function(router, msg)
{
	return A2(_Scheduler_send, router.h, {
		$: 0,
		a: msg
	});
});



// BAGS


function _Platform_leaf(home)
{
	return function(value)
	{
		return {
			$: 1,
			k: home,
			l: value
		};
	};
}


function _Platform_batch(list)
{
	return {
		$: 2,
		m: list
	};
}


var _Platform_map = F2(function(tagger, bag)
{
	return {
		$: 3,
		n: tagger,
		o: bag
	}
});



// PIPE BAGS INTO EFFECT MANAGERS
//
// Effects must be queued!
//
// Say your init contains a synchronous command, like Time.now or Time.here
//
//   - This will produce a batch of effects (FX_1)
//   - The synchronous task triggers the subsequent `update` call
//   - This will produce a batch of effects (FX_2)
//
// If we just start dispatching FX_2, subscriptions from FX_2 can be processed
// before subscriptions from FX_1. No good! Earlier versions of this code had
// this problem, leading to these reports:
//
//   https://github.com/elm/core/issues/980
//   https://github.com/elm/core/pull/981
//   https://github.com/elm/compiler/issues/1776
//
// The queue is necessary to avoid ordering issues for synchronous commands.


// Why use true/false here? Why not just check the length of the queue?
// The goal is to detect "are we currently dispatching effects?" If we
// are, we need to bail and let the ongoing while loop handle things.
//
// Now say the queue has 1 element. When we dequeue the final element,
// the queue will be empty, but we are still actively dispatching effects.
// So you could get queue jumping in a really tricky category of cases.
//
var _Platform_effectsQueue = [];
var _Platform_effectsActive = false;


function _Platform_enqueueEffects(managers, cmdBag, subBag)
{
	_Platform_effectsQueue.push({ p: managers, q: cmdBag, r: subBag });

	if (_Platform_effectsActive) return;

	_Platform_effectsActive = true;
	for (var fx; fx = _Platform_effectsQueue.shift(); )
	{
		_Platform_dispatchEffects(fx.p, fx.q, fx.r);
	}
	_Platform_effectsActive = false;
}


function _Platform_dispatchEffects(managers, cmdBag, subBag)
{
	var effectsDict = {};
	_Platform_gatherEffects(true, cmdBag, effectsDict, null);
	_Platform_gatherEffects(false, subBag, effectsDict, null);

	for (var home in managers)
	{
		_Scheduler_rawSend(managers[home], {
			$: 'fx',
			a: effectsDict[home] || { i: _List_Nil, j: _List_Nil }
		});
	}
}


function _Platform_gatherEffects(isCmd, bag, effectsDict, taggers)
{
	switch (bag.$)
	{
		case 1:
			var home = bag.k;
			var effect = _Platform_toEffect(isCmd, home, taggers, bag.l);
			effectsDict[home] = _Platform_insert(isCmd, effect, effectsDict[home]);
			return;

		case 2:
			for (var list = bag.m; list.b; list = list.b) // WHILE_CONS
			{
				_Platform_gatherEffects(isCmd, list.a, effectsDict, taggers);
			}
			return;

		case 3:
			_Platform_gatherEffects(isCmd, bag.o, effectsDict, {
				s: bag.n,
				t: taggers
			});
			return;
	}
}


function _Platform_toEffect(isCmd, home, taggers, value)
{
	function applyTaggers(x)
	{
		for (var temp = taggers; temp; temp = temp.t)
		{
			x = temp.s(x);
		}
		return x;
	}

	var map = isCmd
		? _Platform_effectManagers[home].e
		: _Platform_effectManagers[home].f;

	return A2(map, applyTaggers, value)
}


function _Platform_insert(isCmd, newEffect, effects)
{
	effects = effects || { i: _List_Nil, j: _List_Nil };

	isCmd
		? (effects.i = _List_Cons(newEffect, effects.i))
		: (effects.j = _List_Cons(newEffect, effects.j));

	return effects;
}



// PORTS


function _Platform_checkPortName(name)
{
	if (_Platform_effectManagers[name])
	{
		_Debug_crash(3, name)
	}
}



// OUTGOING PORTS


function _Platform_outgoingPort(name, converter)
{
	_Platform_checkPortName(name);
	_Platform_effectManagers[name] = {
		e: _Platform_outgoingPortMap,
		u: converter,
		a: _Platform_setupOutgoingPort
	};
	return _Platform_leaf(name);
}


var _Platform_outgoingPortMap = F2(function(tagger, value) { return value; });


function _Platform_setupOutgoingPort(name)
{
	var subs = [];
	var converter = _Platform_effectManagers[name].u;

	// CREATE MANAGER

	var init = _Process_sleep(0);

	_Platform_effectManagers[name].b = init;
	_Platform_effectManagers[name].c = F3(function(router, cmdList, state)
	{
		for ( ; cmdList.b; cmdList = cmdList.b) // WHILE_CONS
		{
			// grab a separate reference to subs in case unsubscribe is called
			var currentSubs = subs;
			var value = _Json_unwrap(converter(cmdList.a));
			for (var i = 0; i < currentSubs.length; i++)
			{
				currentSubs[i](value);
			}
		}
		return init;
	});

	// PUBLIC API

	function subscribe(callback)
	{
		subs.push(callback);
	}

	function unsubscribe(callback)
	{
		// copy subs into a new array in case unsubscribe is called within a
		// subscribed callback
		subs = subs.slice();
		var index = subs.indexOf(callback);
		if (index >= 0)
		{
			subs.splice(index, 1);
		}
	}

	return {
		subscribe: subscribe,
		unsubscribe: unsubscribe
	};
}



// INCOMING PORTS


function _Platform_incomingPort(name, converter)
{
	_Platform_checkPortName(name);
	_Platform_effectManagers[name] = {
		f: _Platform_incomingPortMap,
		u: converter,
		a: _Platform_setupIncomingPort
	};
	return _Platform_leaf(name);
}


var _Platform_incomingPortMap = F2(function(tagger, finalTagger)
{
	return function(value)
	{
		return tagger(finalTagger(value));
	};
});


function _Platform_setupIncomingPort(name, sendToApp)
{
	var subs = _List_Nil;
	var converter = _Platform_effectManagers[name].u;

	// CREATE MANAGER

	var init = _Scheduler_succeed(null);

	_Platform_effectManagers[name].b = init;
	_Platform_effectManagers[name].c = F3(function(router, subList, state)
	{
		subs = subList;
		return init;
	});

	// PUBLIC API

	function send(incomingValue)
	{
		var result = A2(_Json_run, converter, _Json_wrap(incomingValue));

		$elm$core$Result$isOk(result) || _Debug_crash(4, name, result.a);

		var value = result.a;
		for (var temp = subs; temp.b; temp = temp.b) // WHILE_CONS
		{
			sendToApp(temp.a(value));
		}
	}

	return { send: send };
}



// EXPORT ELM MODULES
//
// Have DEBUG and PROD versions so that we can (1) give nicer errors in
// debug mode and (2) not pay for the bits needed for that in prod mode.
//


function _Platform_export_UNUSED(exports)
{
	scope['Elm']
		? _Platform_mergeExportsProd(scope['Elm'], exports)
		: scope['Elm'] = exports;
}


function _Platform_mergeExportsProd(obj, exports)
{
	for (var name in exports)
	{
		(name in obj)
			? (name == 'init')
				? _Debug_crash(6)
				: _Platform_mergeExportsProd(obj[name], exports[name])
			: (obj[name] = exports[name]);
	}
}


function _Platform_export(exports)
{
	scope['Elm']
		? _Platform_mergeExportsDebug('Elm', scope['Elm'], exports)
		: scope['Elm'] = exports;
}


function _Platform_mergeExportsDebug(moduleName, obj, exports)
{
	for (var name in exports)
	{
		(name in obj)
			? (name == 'init')
				? _Debug_crash(6, moduleName)
				: _Platform_mergeExportsDebug(moduleName + '.' + name, obj[name], exports[name])
			: (obj[name] = exports[name]);
	}
}




// HELPERS


var _VirtualDom_divertHrefToApp;

var _VirtualDom_doc = typeof document !== 'undefined' ? document : {};


function _VirtualDom_appendChild(parent, child)
{
	parent.appendChild(child);
}

var _VirtualDom_init = F4(function(virtualNode, flagDecoder, debugMetadata, args)
{
	// NOTE: this function needs _Platform_export available to work

	/**_UNUSED/
	var node = args['node'];
	//*/
	/**/
	var node = args && args['node'] ? args['node'] : _Debug_crash(0);
	//*/

	node.parentNode.replaceChild(
		_VirtualDom_render(virtualNode, function() {}),
		node
	);

	return {};
});



// TEXT


function _VirtualDom_text(string)
{
	return {
		$: 0,
		a: string
	};
}



// NODE


var _VirtualDom_nodeNS = F2(function(namespace, tag)
{
	return F2(function(factList, kidList)
	{
		for (var kids = [], descendantsCount = 0; kidList.b; kidList = kidList.b) // WHILE_CONS
		{
			var kid = kidList.a;
			descendantsCount += (kid.b || 0);
			kids.push(kid);
		}
		descendantsCount += kids.length;

		return {
			$: 1,
			c: tag,
			d: _VirtualDom_organizeFacts(factList),
			e: kids,
			f: namespace,
			b: descendantsCount
		};
	});
});


var _VirtualDom_node = _VirtualDom_nodeNS(undefined);



// KEYED NODE


var _VirtualDom_keyedNodeNS = F2(function(namespace, tag)
{
	return F2(function(factList, kidList)
	{
		for (var kids = [], descendantsCount = 0; kidList.b; kidList = kidList.b) // WHILE_CONS
		{
			var kid = kidList.a;
			descendantsCount += (kid.b.b || 0);
			kids.push(kid);
		}
		descendantsCount += kids.length;

		return {
			$: 2,
			c: tag,
			d: _VirtualDom_organizeFacts(factList),
			e: kids,
			f: namespace,
			b: descendantsCount
		};
	});
});


var _VirtualDom_keyedNode = _VirtualDom_keyedNodeNS(undefined);



// CUSTOM


function _VirtualDom_custom(factList, model, render, diff)
{
	return {
		$: 3,
		d: _VirtualDom_organizeFacts(factList),
		g: model,
		h: render,
		i: diff
	};
}



// MAP


var _VirtualDom_map = F2(function(tagger, node)
{
	return {
		$: 4,
		j: tagger,
		k: node,
		b: 1 + (node.b || 0)
	};
});



// LAZY


function _VirtualDom_thunk(refs, thunk)
{
	return {
		$: 5,
		l: refs,
		m: thunk,
		k: undefined
	};
}

var _VirtualDom_lazy = F2(function(func, a)
{
	return _VirtualDom_thunk([func, a], function() {
		return func(a);
	});
});

var _VirtualDom_lazy2 = F3(function(func, a, b)
{
	return _VirtualDom_thunk([func, a, b], function() {
		return A2(func, a, b);
	});
});

var _VirtualDom_lazy3 = F4(function(func, a, b, c)
{
	return _VirtualDom_thunk([func, a, b, c], function() {
		return A3(func, a, b, c);
	});
});

var _VirtualDom_lazy4 = F5(function(func, a, b, c, d)
{
	return _VirtualDom_thunk([func, a, b, c, d], function() {
		return A4(func, a, b, c, d);
	});
});

var _VirtualDom_lazy5 = F6(function(func, a, b, c, d, e)
{
	return _VirtualDom_thunk([func, a, b, c, d, e], function() {
		return A5(func, a, b, c, d, e);
	});
});

var _VirtualDom_lazy6 = F7(function(func, a, b, c, d, e, f)
{
	return _VirtualDom_thunk([func, a, b, c, d, e, f], function() {
		return A6(func, a, b, c, d, e, f);
	});
});

var _VirtualDom_lazy7 = F8(function(func, a, b, c, d, e, f, g)
{
	return _VirtualDom_thunk([func, a, b, c, d, e, f, g], function() {
		return A7(func, a, b, c, d, e, f, g);
	});
});

var _VirtualDom_lazy8 = F9(function(func, a, b, c, d, e, f, g, h)
{
	return _VirtualDom_thunk([func, a, b, c, d, e, f, g, h], function() {
		return A8(func, a, b, c, d, e, f, g, h);
	});
});



// FACTS


var _VirtualDom_on = F2(function(key, handler)
{
	return {
		$: 'a0',
		n: key,
		o: handler
	};
});
var _VirtualDom_style = F2(function(key, value)
{
	return {
		$: 'a1',
		n: key,
		o: value
	};
});
var _VirtualDom_property = F2(function(key, value)
{
	return {
		$: 'a2',
		n: key,
		o: value
	};
});
var _VirtualDom_attribute = F2(function(key, value)
{
	return {
		$: 'a3',
		n: key,
		o: value
	};
});
var _VirtualDom_attributeNS = F3(function(namespace, key, value)
{
	return {
		$: 'a4',
		n: key,
		o: { f: namespace, o: value }
	};
});



// XSS ATTACK VECTOR CHECKS
//
// For some reason, tabs can appear in href protocols and it still works.
// So '\tjava\tSCRIPT:alert("!!!")' and 'javascript:alert("!!!")' are the same
// in practice. That is why _VirtualDom_RE_js and _VirtualDom_RE_js_html look
// so freaky.
//
// Pulling the regular expressions out to the top level gives a slight speed
// boost in small benchmarks (4-10%) but hoisting values to reduce allocation
// can be unpredictable in large programs where JIT may have a harder time with
// functions are not fully self-contained. The benefit is more that the js and
// js_html ones are so weird that I prefer to see them near each other.


var _VirtualDom_RE_script = /^script$/i;
var _VirtualDom_RE_on_formAction = /^(on|formAction$)/i;
var _VirtualDom_RE_js = /^\s*j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:/i;
var _VirtualDom_RE_js_html = /^\s*(j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*(,|;))/i;


function _VirtualDom_noScript(tag)
{
	return _VirtualDom_RE_script.test(tag) ? 'p' : tag;
}

function _VirtualDom_noOnOrFormAction(key)
{
	return _VirtualDom_RE_on_formAction.test(key) ? 'data-' + key : key;
}

function _VirtualDom_noInnerHtmlOrFormAction(key)
{
	return key == 'innerHTML' || key == 'outerHTML' || key == 'formAction' ? 'data-' + key : key;
}

function _VirtualDom_noJavaScriptUri(value)
{
	return _VirtualDom_RE_js.test(value)
		? /**_UNUSED/''//*//**/'javascript:alert("This is an XSS vector. Please use ports or web components instead.")'//*/
		: value;
}

function _VirtualDom_noJavaScriptOrHtmlUri(value)
{
	return _VirtualDom_RE_js_html.test(value)
		? /**_UNUSED/''//*//**/'javascript:alert("This is an XSS vector. Please use ports or web components instead.")'//*/
		: value;
}

function _VirtualDom_noJavaScriptOrHtmlJson(value)
{
	return (
		(typeof _Json_unwrap(value) === 'string' && _VirtualDom_RE_js_html.test(_Json_unwrap(value)))
		||
		(Array.isArray(_Json_unwrap(value)) && _VirtualDom_RE_js_html.test(String(_Json_unwrap(value))))
	)
		? _Json_wrap(
			/**_UNUSED/''//*//**/'javascript:alert("This is an XSS vector. Please use ports or web components instead.")'//*/
		) : value;
}



// MAP FACTS


var _VirtualDom_mapAttribute = F2(function(func, attr)
{
	return (attr.$ === 'a0')
		? A2(_VirtualDom_on, attr.n, _VirtualDom_mapHandler(func, attr.o))
		: attr;
});

function _VirtualDom_mapHandler(func, handler)
{
	var tag = $elm$virtual_dom$VirtualDom$toHandlerInt(handler);

	// 0 = Normal
	// 1 = MayStopPropagation
	// 2 = MayPreventDefault
	// 3 = Custom

	return {
		$: handler.$,
		a:
			!tag
				? A2($elm$json$Json$Decode$map, func, handler.a)
				:
			A3($elm$json$Json$Decode$map2,
				tag < 3
					? _VirtualDom_mapEventTuple
					: _VirtualDom_mapEventRecord,
				$elm$json$Json$Decode$succeed(func),
				handler.a
			)
	};
}

var _VirtualDom_mapEventTuple = F2(function(func, tuple)
{
	return _Utils_Tuple2(func(tuple.a), tuple.b);
});

var _VirtualDom_mapEventRecord = F2(function(func, record)
{
	return {
		message: func(record.message),
		stopPropagation: record.stopPropagation,
		preventDefault: record.preventDefault
	}
});



// ORGANIZE FACTS


function _VirtualDom_organizeFacts(factList)
{
	for (var facts = {}; factList.b; factList = factList.b) // WHILE_CONS
	{
		var entry = factList.a;

		var tag = entry.$;
		var key = entry.n;
		var value = entry.o;

		if (tag === 'a2')
		{
			(key === 'className')
				? _VirtualDom_addClass(facts, key, _Json_unwrap(value))
				: facts[key] = _Json_unwrap(value);

			continue;
		}

		var subFacts = facts[tag] || (facts[tag] = {});
		(tag === 'a3' && key === 'class')
			? _VirtualDom_addClass(subFacts, key, value)
			: subFacts[key] = value;
	}

	return facts;
}

function _VirtualDom_addClass(object, key, newClass)
{
	var classes = object[key];
	object[key] = classes ? classes + ' ' + newClass : newClass;
}



// RENDER


function _VirtualDom_render(vNode, eventNode)
{
	var tag = vNode.$;

	if (tag === 5)
	{
		return _VirtualDom_render(vNode.k || (vNode.k = vNode.m()), eventNode);
	}

	if (tag === 0)
	{
		return _VirtualDom_doc.createTextNode(vNode.a);
	}

	if (tag === 4)
	{
		var subNode = vNode.k;
		var tagger = vNode.j;

		while (subNode.$ === 4)
		{
			typeof tagger !== 'object'
				? tagger = [tagger, subNode.j]
				: tagger.push(subNode.j);

			subNode = subNode.k;
		}

		var subEventRoot = { j: tagger, p: eventNode };
		var domNode = _VirtualDom_render(subNode, subEventRoot);
		domNode.elm_event_node_ref = subEventRoot;
		return domNode;
	}

	if (tag === 3)
	{
		var domNode = vNode.h(vNode.g);
		_VirtualDom_applyFacts(domNode, eventNode, vNode.d);
		return domNode;
	}

	// at this point `tag` must be 1 or 2

	var domNode = vNode.f
		? _VirtualDom_doc.createElementNS(vNode.f, vNode.c)
		: _VirtualDom_doc.createElement(vNode.c);

	if (_VirtualDom_divertHrefToApp && vNode.c == 'a')
	{
		domNode.addEventListener('click', _VirtualDom_divertHrefToApp(domNode));
	}

	_VirtualDom_applyFacts(domNode, eventNode, vNode.d);

	for (var kids = vNode.e, i = 0; i < kids.length; i++)
	{
		_VirtualDom_appendChild(domNode, _VirtualDom_render(tag === 1 ? kids[i] : kids[i].b, eventNode));
	}

	return domNode;
}



// APPLY FACTS


function _VirtualDom_applyFacts(domNode, eventNode, facts)
{
	for (var key in facts)
	{
		var value = facts[key];

		key === 'a1'
			? _VirtualDom_applyStyles(domNode, value)
			:
		key === 'a0'
			? _VirtualDom_applyEvents(domNode, eventNode, value)
			:
		key === 'a3'
			? _VirtualDom_applyAttrs(domNode, value)
			:
		key === 'a4'
			? _VirtualDom_applyAttrsNS(domNode, value)
			:
		((key !== 'value' && key !== 'checked') || domNode[key] !== value) && (domNode[key] = value);
	}
}



// APPLY STYLES


function _VirtualDom_applyStyles(domNode, styles)
{
	var domNodeStyle = domNode.style;

	for (var key in styles)
	{
		domNodeStyle[key] = styles[key];
	}
}



// APPLY ATTRS


function _VirtualDom_applyAttrs(domNode, attrs)
{
	for (var key in attrs)
	{
		var value = attrs[key];
		typeof value !== 'undefined'
			? domNode.setAttribute(key, value)
			: domNode.removeAttribute(key);
	}
}



// APPLY NAMESPACED ATTRS


function _VirtualDom_applyAttrsNS(domNode, nsAttrs)
{
	for (var key in nsAttrs)
	{
		var pair = nsAttrs[key];
		var namespace = pair.f;
		var value = pair.o;

		typeof value !== 'undefined'
			? domNode.setAttributeNS(namespace, key, value)
			: domNode.removeAttributeNS(namespace, key);
	}
}



// APPLY EVENTS


function _VirtualDom_applyEvents(domNode, eventNode, events)
{
	var allCallbacks = domNode.elmFs || (domNode.elmFs = {});

	for (var key in events)
	{
		var newHandler = events[key];
		var oldCallback = allCallbacks[key];

		if (!newHandler)
		{
			domNode.removeEventListener(key, oldCallback);
			allCallbacks[key] = undefined;
			continue;
		}

		if (oldCallback)
		{
			var oldHandler = oldCallback.q;
			if (oldHandler.$ === newHandler.$)
			{
				oldCallback.q = newHandler;
				continue;
			}
			domNode.removeEventListener(key, oldCallback);
		}

		oldCallback = _VirtualDom_makeCallback(eventNode, newHandler);
		domNode.addEventListener(key, oldCallback,
			_VirtualDom_passiveSupported
			&& { passive: $elm$virtual_dom$VirtualDom$toHandlerInt(newHandler) < 2 }
		);
		allCallbacks[key] = oldCallback;
	}
}



// PASSIVE EVENTS


var _VirtualDom_passiveSupported;

try
{
	window.addEventListener('t', null, Object.defineProperty({}, 'passive', {
		get: function() { _VirtualDom_passiveSupported = true; }
	}));
}
catch(e) {}



// EVENT HANDLERS


function _VirtualDom_makeCallback(eventNode, initialHandler)
{
	function callback(event)
	{
		var handler = callback.q;
		var result = _Json_runHelp(handler.a, event);

		if (!$elm$core$Result$isOk(result))
		{
			return;
		}

		var tag = $elm$virtual_dom$VirtualDom$toHandlerInt(handler);

		// 0 = Normal
		// 1 = MayStopPropagation
		// 2 = MayPreventDefault
		// 3 = Custom

		var value = result.a;
		var message = !tag ? value : tag < 3 ? value.a : value.message;
		var stopPropagation = tag == 1 ? value.b : tag == 3 && value.stopPropagation;
		var currentEventNode = (
			stopPropagation && event.stopPropagation(),
			(tag == 2 ? value.b : tag == 3 && value.preventDefault) && event.preventDefault(),
			eventNode
		);
		var tagger;
		var i;
		while (tagger = currentEventNode.j)
		{
			if (typeof tagger == 'function')
			{
				message = tagger(message);
			}
			else
			{
				for (var i = tagger.length; i--; )
				{
					message = tagger[i](message);
				}
			}
			currentEventNode = currentEventNode.p;
		}
		currentEventNode(message, stopPropagation); // stopPropagation implies isSync
	}

	callback.q = initialHandler;

	return callback;
}

function _VirtualDom_equalEvents(x, y)
{
	return x.$ == y.$ && _Json_equality(x.a, y.a);
}



// DIFF


// TODO: Should we do patches like in iOS?
//
// type Patch
//   = At Int Patch
//   | Batch (List Patch)
//   | Change ...
//
// How could it not be better?
//
function _VirtualDom_diff(x, y)
{
	var patches = [];
	_VirtualDom_diffHelp(x, y, patches, 0);
	return patches;
}


function _VirtualDom_pushPatch(patches, type, index, data)
{
	var patch = {
		$: type,
		r: index,
		s: data,
		t: undefined,
		u: undefined
	};
	patches.push(patch);
	return patch;
}


function _VirtualDom_diffHelp(x, y, patches, index)
{
	if (x === y)
	{
		return;
	}

	var xType = x.$;
	var yType = y.$;

	// Bail if you run into different types of nodes. Implies that the
	// structure has changed significantly and it's not worth a diff.
	if (xType !== yType)
	{
		if (xType === 1 && yType === 2)
		{
			y = _VirtualDom_dekey(y);
			yType = 1;
		}
		else
		{
			_VirtualDom_pushPatch(patches, 0, index, y);
			return;
		}
	}

	// Now we know that both nodes are the same $.
	switch (yType)
	{
		case 5:
			var xRefs = x.l;
			var yRefs = y.l;
			var i = xRefs.length;
			var same = i === yRefs.length;
			while (same && i--)
			{
				same = xRefs[i] === yRefs[i];
			}
			if (same)
			{
				y.k = x.k;
				return;
			}
			y.k = y.m();
			var subPatches = [];
			_VirtualDom_diffHelp(x.k, y.k, subPatches, 0);
			subPatches.length > 0 && _VirtualDom_pushPatch(patches, 1, index, subPatches);
			return;

		case 4:
			// gather nested taggers
			var xTaggers = x.j;
			var yTaggers = y.j;
			var nesting = false;

			var xSubNode = x.k;
			while (xSubNode.$ === 4)
			{
				nesting = true;

				typeof xTaggers !== 'object'
					? xTaggers = [xTaggers, xSubNode.j]
					: xTaggers.push(xSubNode.j);

				xSubNode = xSubNode.k;
			}

			var ySubNode = y.k;
			while (ySubNode.$ === 4)
			{
				nesting = true;

				typeof yTaggers !== 'object'
					? yTaggers = [yTaggers, ySubNode.j]
					: yTaggers.push(ySubNode.j);

				ySubNode = ySubNode.k;
			}

			// Just bail if different numbers of taggers. This implies the
			// structure of the virtual DOM has changed.
			if (nesting && xTaggers.length !== yTaggers.length)
			{
				_VirtualDom_pushPatch(patches, 0, index, y);
				return;
			}

			// check if taggers are "the same"
			if (nesting ? !_VirtualDom_pairwiseRefEqual(xTaggers, yTaggers) : xTaggers !== yTaggers)
			{
				_VirtualDom_pushPatch(patches, 2, index, yTaggers);
			}

			// diff everything below the taggers
			_VirtualDom_diffHelp(xSubNode, ySubNode, patches, index + 1);
			return;

		case 0:
			if (x.a !== y.a)
			{
				_VirtualDom_pushPatch(patches, 3, index, y.a);
			}
			return;

		case 1:
			_VirtualDom_diffNodes(x, y, patches, index, _VirtualDom_diffKids);
			return;

		case 2:
			_VirtualDom_diffNodes(x, y, patches, index, _VirtualDom_diffKeyedKids);
			return;

		case 3:
			if (x.h !== y.h)
			{
				_VirtualDom_pushPatch(patches, 0, index, y);
				return;
			}

			var factsDiff = _VirtualDom_diffFacts(x.d, y.d);
			factsDiff && _VirtualDom_pushPatch(patches, 4, index, factsDiff);

			var patch = y.i(x.g, y.g);
			patch && _VirtualDom_pushPatch(patches, 5, index, patch);

			return;
	}
}

// assumes the incoming arrays are the same length
function _VirtualDom_pairwiseRefEqual(as, bs)
{
	for (var i = 0; i < as.length; i++)
	{
		if (as[i] !== bs[i])
		{
			return false;
		}
	}

	return true;
}

function _VirtualDom_diffNodes(x, y, patches, index, diffKids)
{
	// Bail if obvious indicators have changed. Implies more serious
	// structural changes such that it's not worth it to diff.
	if (x.c !== y.c || x.f !== y.f)
	{
		_VirtualDom_pushPatch(patches, 0, index, y);
		return;
	}

	var factsDiff = _VirtualDom_diffFacts(x.d, y.d);
	factsDiff && _VirtualDom_pushPatch(patches, 4, index, factsDiff);

	diffKids(x, y, patches, index);
}



// DIFF FACTS


// TODO Instead of creating a new diff object, it's possible to just test if
// there *is* a diff. During the actual patch, do the diff again and make the
// modifications directly. This way, there's no new allocations. Worth it?
function _VirtualDom_diffFacts(x, y, category)
{
	var diff;

	// look for changes and removals
	for (var xKey in x)
	{
		if (xKey === 'a1' || xKey === 'a0' || xKey === 'a3' || xKey === 'a4')
		{
			var subDiff = _VirtualDom_diffFacts(x[xKey], y[xKey] || {}, xKey);
			if (subDiff)
			{
				diff = diff || {};
				diff[xKey] = subDiff;
			}
			continue;
		}

		// remove if not in the new facts
		if (!(xKey in y))
		{
			diff = diff || {};
			diff[xKey] =
				!category
					? (typeof x[xKey] === 'string' ? '' : null)
					:
				(category === 'a1')
					? ''
					:
				(category === 'a0' || category === 'a3')
					? undefined
					:
				{ f: x[xKey].f, o: undefined };

			continue;
		}

		var xValue = x[xKey];
		var yValue = y[xKey];

		// reference equal, so don't worry about it
		if (xValue === yValue && xKey !== 'value' && xKey !== 'checked'
			|| category === 'a0' && _VirtualDom_equalEvents(xValue, yValue))
		{
			continue;
		}

		diff = diff || {};
		diff[xKey] = yValue;
	}

	// add new stuff
	for (var yKey in y)
	{
		if (!(yKey in x))
		{
			diff = diff || {};
			diff[yKey] = y[yKey];
		}
	}

	return diff;
}



// DIFF KIDS


function _VirtualDom_diffKids(xParent, yParent, patches, index)
{
	var xKids = xParent.e;
	var yKids = yParent.e;

	var xLen = xKids.length;
	var yLen = yKids.length;

	// FIGURE OUT IF THERE ARE INSERTS OR REMOVALS

	if (xLen > yLen)
	{
		_VirtualDom_pushPatch(patches, 6, index, {
			v: yLen,
			i: xLen - yLen
		});
	}
	else if (xLen < yLen)
	{
		_VirtualDom_pushPatch(patches, 7, index, {
			v: xLen,
			e: yKids
		});
	}

	// PAIRWISE DIFF EVERYTHING ELSE

	for (var minLen = xLen < yLen ? xLen : yLen, i = 0; i < minLen; i++)
	{
		var xKid = xKids[i];
		_VirtualDom_diffHelp(xKid, yKids[i], patches, ++index);
		index += xKid.b || 0;
	}
}



// KEYED DIFF


function _VirtualDom_diffKeyedKids(xParent, yParent, patches, rootIndex)
{
	var localPatches = [];

	var changes = {}; // Dict String Entry
	var inserts = []; // Array { index : Int, entry : Entry }
	// type Entry = { tag : String, vnode : VNode, index : Int, data : _ }

	var xKids = xParent.e;
	var yKids = yParent.e;
	var xLen = xKids.length;
	var yLen = yKids.length;
	var xIndex = 0;
	var yIndex = 0;

	var index = rootIndex;

	while (xIndex < xLen && yIndex < yLen)
	{
		var x = xKids[xIndex];
		var y = yKids[yIndex];

		var xKey = x.a;
		var yKey = y.a;
		var xNode = x.b;
		var yNode = y.b;

		var newMatch = undefined;
		var oldMatch = undefined;

		// check if keys match

		if (xKey === yKey)
		{
			index++;
			_VirtualDom_diffHelp(xNode, yNode, localPatches, index);
			index += xNode.b || 0;

			xIndex++;
			yIndex++;
			continue;
		}

		// look ahead 1 to detect insertions and removals.

		var xNext = xKids[xIndex + 1];
		var yNext = yKids[yIndex + 1];

		if (xNext)
		{
			var xNextKey = xNext.a;
			var xNextNode = xNext.b;
			oldMatch = yKey === xNextKey;
		}

		if (yNext)
		{
			var yNextKey = yNext.a;
			var yNextNode = yNext.b;
			newMatch = xKey === yNextKey;
		}


		// swap x and y
		if (newMatch && oldMatch)
		{
			index++;
			_VirtualDom_diffHelp(xNode, yNextNode, localPatches, index);
			_VirtualDom_insertNode(changes, localPatches, xKey, yNode, yIndex, inserts);
			index += xNode.b || 0;

			index++;
			_VirtualDom_removeNode(changes, localPatches, xKey, xNextNode, index);
			index += xNextNode.b || 0;

			xIndex += 2;
			yIndex += 2;
			continue;
		}

		// insert y
		if (newMatch)
		{
			index++;
			_VirtualDom_insertNode(changes, localPatches, yKey, yNode, yIndex, inserts);
			_VirtualDom_diffHelp(xNode, yNextNode, localPatches, index);
			index += xNode.b || 0;

			xIndex += 1;
			yIndex += 2;
			continue;
		}

		// remove x
		if (oldMatch)
		{
			index++;
			_VirtualDom_removeNode(changes, localPatches, xKey, xNode, index);
			index += xNode.b || 0;

			index++;
			_VirtualDom_diffHelp(xNextNode, yNode, localPatches, index);
			index += xNextNode.b || 0;

			xIndex += 2;
			yIndex += 1;
			continue;
		}

		// remove x, insert y
		if (xNext && xNextKey === yNextKey)
		{
			index++;
			_VirtualDom_removeNode(changes, localPatches, xKey, xNode, index);
			_VirtualDom_insertNode(changes, localPatches, yKey, yNode, yIndex, inserts);
			index += xNode.b || 0;

			index++;
			_VirtualDom_diffHelp(xNextNode, yNextNode, localPatches, index);
			index += xNextNode.b || 0;

			xIndex += 2;
			yIndex += 2;
			continue;
		}

		break;
	}

	// eat up any remaining nodes with removeNode and insertNode

	while (xIndex < xLen)
	{
		index++;
		var x = xKids[xIndex];
		var xNode = x.b;
		_VirtualDom_removeNode(changes, localPatches, x.a, xNode, index);
		index += xNode.b || 0;
		xIndex++;
	}

	while (yIndex < yLen)
	{
		var endInserts = endInserts || [];
		var y = yKids[yIndex];
		_VirtualDom_insertNode(changes, localPatches, y.a, y.b, undefined, endInserts);
		yIndex++;
	}

	if (localPatches.length > 0 || inserts.length > 0 || endInserts)
	{
		_VirtualDom_pushPatch(patches, 8, rootIndex, {
			w: localPatches,
			x: inserts,
			y: endInserts
		});
	}
}



// CHANGES FROM KEYED DIFF


var _VirtualDom_POSTFIX = '_elmW6BL';


function _VirtualDom_insertNode(changes, localPatches, key, vnode, yIndex, inserts)
{
	var entry = changes[key];

	// never seen this key before
	if (!entry)
	{
		entry = {
			c: 0,
			z: vnode,
			r: yIndex,
			s: undefined
		};

		inserts.push({ r: yIndex, A: entry });
		changes[key] = entry;

		return;
	}

	// this key was removed earlier, a match!
	if (entry.c === 1)
	{
		inserts.push({ r: yIndex, A: entry });

		entry.c = 2;
		var subPatches = [];
		_VirtualDom_diffHelp(entry.z, vnode, subPatches, entry.r);
		entry.r = yIndex;
		entry.s.s = {
			w: subPatches,
			A: entry
		};

		return;
	}

	// this key has already been inserted or moved, a duplicate!
	_VirtualDom_insertNode(changes, localPatches, key + _VirtualDom_POSTFIX, vnode, yIndex, inserts);
}


function _VirtualDom_removeNode(changes, localPatches, key, vnode, index)
{
	var entry = changes[key];

	// never seen this key before
	if (!entry)
	{
		var patch = _VirtualDom_pushPatch(localPatches, 9, index, undefined);

		changes[key] = {
			c: 1,
			z: vnode,
			r: index,
			s: patch
		};

		return;
	}

	// this key was inserted earlier, a match!
	if (entry.c === 0)
	{
		entry.c = 2;
		var subPatches = [];
		_VirtualDom_diffHelp(vnode, entry.z, subPatches, index);

		_VirtualDom_pushPatch(localPatches, 9, index, {
			w: subPatches,
			A: entry
		});

		return;
	}

	// this key has already been removed or moved, a duplicate!
	_VirtualDom_removeNode(changes, localPatches, key + _VirtualDom_POSTFIX, vnode, index);
}



// ADD DOM NODES
//
// Each DOM node has an "index" assigned in order of traversal. It is important
// to minimize our crawl over the actual DOM, so these indexes (along with the
// descendantsCount of virtual nodes) let us skip touching entire subtrees of
// the DOM if we know there are no patches there.


function _VirtualDom_addDomNodes(domNode, vNode, patches, eventNode)
{
	_VirtualDom_addDomNodesHelp(domNode, vNode, patches, 0, 0, vNode.b, eventNode);
}


// assumes `patches` is non-empty and indexes increase monotonically.
function _VirtualDom_addDomNodesHelp(domNode, vNode, patches, i, low, high, eventNode)
{
	var patch = patches[i];
	var index = patch.r;

	while (index === low)
	{
		var patchType = patch.$;

		if (patchType === 1)
		{
			_VirtualDom_addDomNodes(domNode, vNode.k, patch.s, eventNode);
		}
		else if (patchType === 8)
		{
			patch.t = domNode;
			patch.u = eventNode;

			var subPatches = patch.s.w;
			if (subPatches.length > 0)
			{
				_VirtualDom_addDomNodesHelp(domNode, vNode, subPatches, 0, low, high, eventNode);
			}
		}
		else if (patchType === 9)
		{
			patch.t = domNode;
			patch.u = eventNode;

			var data = patch.s;
			if (data)
			{
				data.A.s = domNode;
				var subPatches = data.w;
				if (subPatches.length > 0)
				{
					_VirtualDom_addDomNodesHelp(domNode, vNode, subPatches, 0, low, high, eventNode);
				}
			}
		}
		else
		{
			patch.t = domNode;
			patch.u = eventNode;
		}

		i++;

		if (!(patch = patches[i]) || (index = patch.r) > high)
		{
			return i;
		}
	}

	var tag = vNode.$;

	if (tag === 4)
	{
		var subNode = vNode.k;

		while (subNode.$ === 4)
		{
			subNode = subNode.k;
		}

		return _VirtualDom_addDomNodesHelp(domNode, subNode, patches, i, low + 1, high, domNode.elm_event_node_ref);
	}

	// tag must be 1 or 2 at this point

	var vKids = vNode.e;
	var childNodes = domNode.childNodes;
	for (var j = 0; j < vKids.length; j++)
	{
		low++;
		var vKid = tag === 1 ? vKids[j] : vKids[j].b;
		var nextLow = low + (vKid.b || 0);
		if (low <= index && index <= nextLow)
		{
			i = _VirtualDom_addDomNodesHelp(childNodes[j], vKid, patches, i, low, nextLow, eventNode);
			if (!(patch = patches[i]) || (index = patch.r) > high)
			{
				return i;
			}
		}
		low = nextLow;
	}
	return i;
}



// APPLY PATCHES


function _VirtualDom_applyPatches(rootDomNode, oldVirtualNode, patches, eventNode)
{
	if (patches.length === 0)
	{
		return rootDomNode;
	}

	_VirtualDom_addDomNodes(rootDomNode, oldVirtualNode, patches, eventNode);
	return _VirtualDom_applyPatchesHelp(rootDomNode, patches);
}

function _VirtualDom_applyPatchesHelp(rootDomNode, patches)
{
	for (var i = 0; i < patches.length; i++)
	{
		var patch = patches[i];
		var localDomNode = patch.t
		var newNode = _VirtualDom_applyPatch(localDomNode, patch);
		if (localDomNode === rootDomNode)
		{
			rootDomNode = newNode;
		}
	}
	return rootDomNode;
}

function _VirtualDom_applyPatch(domNode, patch)
{
	switch (patch.$)
	{
		case 0:
			return _VirtualDom_applyPatchRedraw(domNode, patch.s, patch.u);

		case 4:
			_VirtualDom_applyFacts(domNode, patch.u, patch.s);
			return domNode;

		case 3:
			domNode.replaceData(0, domNode.length, patch.s);
			return domNode;

		case 1:
			return _VirtualDom_applyPatchesHelp(domNode, patch.s);

		case 2:
			if (domNode.elm_event_node_ref)
			{
				domNode.elm_event_node_ref.j = patch.s;
			}
			else
			{
				domNode.elm_event_node_ref = { j: patch.s, p: patch.u };
			}
			return domNode;

		case 6:
			var data = patch.s;
			for (var i = 0; i < data.i; i++)
			{
				domNode.removeChild(domNode.childNodes[data.v]);
			}
			return domNode;

		case 7:
			var data = patch.s;
			var kids = data.e;
			var i = data.v;
			var theEnd = domNode.childNodes[i];
			for (; i < kids.length; i++)
			{
				domNode.insertBefore(_VirtualDom_render(kids[i], patch.u), theEnd);
			}
			return domNode;

		case 9:
			var data = patch.s;
			if (!data)
			{
				domNode.parentNode.removeChild(domNode);
				return domNode;
			}
			var entry = data.A;
			if (typeof entry.r !== 'undefined')
			{
				domNode.parentNode.removeChild(domNode);
			}
			entry.s = _VirtualDom_applyPatchesHelp(domNode, data.w);
			return domNode;

		case 8:
			return _VirtualDom_applyPatchReorder(domNode, patch);

		case 5:
			return patch.s(domNode);

		default:
			_Debug_crash(10); // 'Ran into an unknown patch!'
	}
}


function _VirtualDom_applyPatchRedraw(domNode, vNode, eventNode)
{
	var parentNode = domNode.parentNode;
	var newNode = _VirtualDom_render(vNode, eventNode);

	if (!newNode.elm_event_node_ref)
	{
		newNode.elm_event_node_ref = domNode.elm_event_node_ref;
	}

	if (parentNode && newNode !== domNode)
	{
		parentNode.replaceChild(newNode, domNode);
	}
	return newNode;
}


function _VirtualDom_applyPatchReorder(domNode, patch)
{
	var data = patch.s;

	// remove end inserts
	var frag = _VirtualDom_applyPatchReorderEndInsertsHelp(data.y, patch);

	// removals
	domNode = _VirtualDom_applyPatchesHelp(domNode, data.w);

	// inserts
	var inserts = data.x;
	for (var i = 0; i < inserts.length; i++)
	{
		var insert = inserts[i];
		var entry = insert.A;
		var node = entry.c === 2
			? entry.s
			: _VirtualDom_render(entry.z, patch.u);
		domNode.insertBefore(node, domNode.childNodes[insert.r]);
	}

	// add end inserts
	if (frag)
	{
		_VirtualDom_appendChild(domNode, frag);
	}

	return domNode;
}


function _VirtualDom_applyPatchReorderEndInsertsHelp(endInserts, patch)
{
	if (!endInserts)
	{
		return;
	}

	var frag = _VirtualDom_doc.createDocumentFragment();
	for (var i = 0; i < endInserts.length; i++)
	{
		var insert = endInserts[i];
		var entry = insert.A;
		_VirtualDom_appendChild(frag, entry.c === 2
			? entry.s
			: _VirtualDom_render(entry.z, patch.u)
		);
	}
	return frag;
}


function _VirtualDom_virtualize(node)
{
	// TEXT NODES

	if (node.nodeType === 3)
	{
		return _VirtualDom_text(node.textContent);
	}


	// WEIRD NODES

	if (node.nodeType !== 1)
	{
		return _VirtualDom_text('');
	}


	// ELEMENT NODES

	var attrList = _List_Nil;
	var attrs = node.attributes;
	for (var i = attrs.length; i--; )
	{
		var attr = attrs[i];
		var name = attr.name;
		var value = attr.value;
		attrList = _List_Cons( A2(_VirtualDom_attribute, name, value), attrList );
	}

	var tag = node.tagName.toLowerCase();
	var kidList = _List_Nil;
	var kids = node.childNodes;

	for (var i = kids.length; i--; )
	{
		kidList = _List_Cons(_VirtualDom_virtualize(kids[i]), kidList);
	}
	return A3(_VirtualDom_node, tag, attrList, kidList);
}

function _VirtualDom_dekey(keyedNode)
{
	var keyedKids = keyedNode.e;
	var len = keyedKids.length;
	var kids = new Array(len);
	for (var i = 0; i < len; i++)
	{
		kids[i] = keyedKids[i].b;
	}

	return {
		$: 1,
		c: keyedNode.c,
		d: keyedNode.d,
		e: kids,
		f: keyedNode.f,
		b: keyedNode.b
	};
}




// ELEMENT


var _Debugger_element;

var _Browser_element = _Debugger_element || F4(function(impl, flagDecoder, debugMetadata, args)
{
	return _Platform_initialize(
		flagDecoder,
		args,
		impl.init,
		impl.update,
		impl.subscriptions,
		function(sendToApp, initialModel) {
			var view = impl.view;
			/**_UNUSED/
			var domNode = args['node'];
			//*/
			/**/
			var domNode = args && args['node'] ? args['node'] : _Debug_crash(0);
			//*/
			var currNode = _VirtualDom_virtualize(domNode);

			return _Browser_makeAnimator(initialModel, function(model)
			{
				var nextNode = view(model);
				var patches = _VirtualDom_diff(currNode, nextNode);
				domNode = _VirtualDom_applyPatches(domNode, currNode, patches, sendToApp);
				currNode = nextNode;
			});
		}
	);
});



// DOCUMENT


var _Debugger_document;

var _Browser_document = _Debugger_document || F4(function(impl, flagDecoder, debugMetadata, args)
{
	return _Platform_initialize(
		flagDecoder,
		args,
		impl.init,
		impl.update,
		impl.subscriptions,
		function(sendToApp, initialModel) {
			var divertHrefToApp = impl.setup && impl.setup(sendToApp)
			var view = impl.view;
			var title = _VirtualDom_doc.title;
			var bodyNode = _VirtualDom_doc.body;
			var currNode = _VirtualDom_virtualize(bodyNode);
			return _Browser_makeAnimator(initialModel, function(model)
			{
				_VirtualDom_divertHrefToApp = divertHrefToApp;
				var doc = view(model);
				var nextNode = _VirtualDom_node('body')(_List_Nil)(doc.body);
				var patches = _VirtualDom_diff(currNode, nextNode);
				bodyNode = _VirtualDom_applyPatches(bodyNode, currNode, patches, sendToApp);
				currNode = nextNode;
				_VirtualDom_divertHrefToApp = 0;
				(title !== doc.title) && (_VirtualDom_doc.title = title = doc.title);
			});
		}
	);
});



// ANIMATION


var _Browser_cancelAnimationFrame =
	typeof cancelAnimationFrame !== 'undefined'
		? cancelAnimationFrame
		: function(id) { clearTimeout(id); };

var _Browser_requestAnimationFrame =
	typeof requestAnimationFrame !== 'undefined'
		? requestAnimationFrame
		: function(callback) { return setTimeout(callback, 1000 / 60); };


function _Browser_makeAnimator(model, draw)
{
	draw(model);

	var state = 0;

	function updateIfNeeded()
	{
		state = state === 1
			? 0
			: ( _Browser_requestAnimationFrame(updateIfNeeded), draw(model), 1 );
	}

	return function(nextModel, isSync)
	{
		model = nextModel;

		isSync
			? ( draw(model),
				state === 2 && (state = 1)
				)
			: ( state === 0 && _Browser_requestAnimationFrame(updateIfNeeded),
				state = 2
				);
	};
}



// APPLICATION


function _Browser_application(impl)
{
	var onUrlChange = impl.onUrlChange;
	var onUrlRequest = impl.onUrlRequest;
	var key = function() { key.a(onUrlChange(_Browser_getUrl())); };

	return _Browser_document({
		setup: function(sendToApp)
		{
			key.a = sendToApp;
			_Browser_window.addEventListener('popstate', key);
			_Browser_window.navigator.userAgent.indexOf('Trident') < 0 || _Browser_window.addEventListener('hashchange', key);

			return F2(function(domNode, event)
			{
				if (!event.ctrlKey && !event.metaKey && !event.shiftKey && event.button < 1 && !domNode.target && !domNode.hasAttribute('download'))
				{
					event.preventDefault();
					var href = domNode.href;
					var curr = _Browser_getUrl();
					var next = $elm$url$Url$fromString(href).a;
					sendToApp(onUrlRequest(
						(next
							&& curr.protocol === next.protocol
							&& curr.host === next.host
							&& curr.port_.a === next.port_.a
						)
							? $elm$browser$Browser$Internal(next)
							: $elm$browser$Browser$External(href)
					));
				}
			});
		},
		init: function(flags)
		{
			return A3(impl.init, flags, _Browser_getUrl(), key);
		},
		view: impl.view,
		update: impl.update,
		subscriptions: impl.subscriptions
	});
}

function _Browser_getUrl()
{
	return $elm$url$Url$fromString(_VirtualDom_doc.location.href).a || _Debug_crash(1);
}

var _Browser_go = F2(function(key, n)
{
	return A2($elm$core$Task$perform, $elm$core$Basics$never, _Scheduler_binding(function() {
		n && history.go(n);
		key();
	}));
});

var _Browser_pushUrl = F2(function(key, url)
{
	return A2($elm$core$Task$perform, $elm$core$Basics$never, _Scheduler_binding(function() {
		history.pushState({}, '', url);
		key();
	}));
});

var _Browser_replaceUrl = F2(function(key, url)
{
	return A2($elm$core$Task$perform, $elm$core$Basics$never, _Scheduler_binding(function() {
		history.replaceState({}, '', url);
		key();
	}));
});



// GLOBAL EVENTS


var _Browser_fakeNode = { addEventListener: function() {}, removeEventListener: function() {} };
var _Browser_doc = typeof document !== 'undefined' ? document : _Browser_fakeNode;
var _Browser_window = typeof window !== 'undefined' ? window : _Browser_fakeNode;

var _Browser_on = F3(function(node, eventName, sendToSelf)
{
	return _Scheduler_spawn(_Scheduler_binding(function(callback)
	{
		function handler(event)	{ _Scheduler_rawSpawn(sendToSelf(event)); }
		node.addEventListener(eventName, handler, _VirtualDom_passiveSupported && { passive: true });
		return function() { node.removeEventListener(eventName, handler); };
	}));
});

var _Browser_decodeEvent = F2(function(decoder, event)
{
	var result = _Json_runHelp(decoder, event);
	return $elm$core$Result$isOk(result) ? $elm$core$Maybe$Just(result.a) : $elm$core$Maybe$Nothing;
});



// PAGE VISIBILITY


function _Browser_visibilityInfo()
{
	return (typeof _VirtualDom_doc.hidden !== 'undefined')
		? { hidden: 'hidden', change: 'visibilitychange' }
		:
	(typeof _VirtualDom_doc.mozHidden !== 'undefined')
		? { hidden: 'mozHidden', change: 'mozvisibilitychange' }
		:
	(typeof _VirtualDom_doc.msHidden !== 'undefined')
		? { hidden: 'msHidden', change: 'msvisibilitychange' }
		:
	(typeof _VirtualDom_doc.webkitHidden !== 'undefined')
		? { hidden: 'webkitHidden', change: 'webkitvisibilitychange' }
		: { hidden: 'hidden', change: 'visibilitychange' };
}



// ANIMATION FRAMES


function _Browser_rAF()
{
	return _Scheduler_binding(function(callback)
	{
		var id = _Browser_requestAnimationFrame(function() {
			callback(_Scheduler_succeed(Date.now()));
		});

		return function() {
			_Browser_cancelAnimationFrame(id);
		};
	});
}


function _Browser_now()
{
	return _Scheduler_binding(function(callback)
	{
		callback(_Scheduler_succeed(Date.now()));
	});
}



// DOM STUFF


function _Browser_withNode(id, doStuff)
{
	return _Scheduler_binding(function(callback)
	{
		_Browser_requestAnimationFrame(function() {
			var node = document.getElementById(id);
			callback(node
				? _Scheduler_succeed(doStuff(node))
				: _Scheduler_fail($elm$browser$Browser$Dom$NotFound(id))
			);
		});
	});
}


function _Browser_withWindow(doStuff)
{
	return _Scheduler_binding(function(callback)
	{
		_Browser_requestAnimationFrame(function() {
			callback(_Scheduler_succeed(doStuff()));
		});
	});
}


// FOCUS and BLUR


var _Browser_call = F2(function(functionName, id)
{
	return _Browser_withNode(id, function(node) {
		node[functionName]();
		return _Utils_Tuple0;
	});
});



// WINDOW VIEWPORT


function _Browser_getViewport()
{
	return {
		scene: _Browser_getScene(),
		viewport: {
			x: _Browser_window.pageXOffset,
			y: _Browser_window.pageYOffset,
			width: _Browser_doc.documentElement.clientWidth,
			height: _Browser_doc.documentElement.clientHeight
		}
	};
}

function _Browser_getScene()
{
	var body = _Browser_doc.body;
	var elem = _Browser_doc.documentElement;
	return {
		width: Math.max(body.scrollWidth, body.offsetWidth, elem.scrollWidth, elem.offsetWidth, elem.clientWidth),
		height: Math.max(body.scrollHeight, body.offsetHeight, elem.scrollHeight, elem.offsetHeight, elem.clientHeight)
	};
}

var _Browser_setViewport = F2(function(x, y)
{
	return _Browser_withWindow(function()
	{
		_Browser_window.scroll(x, y);
		return _Utils_Tuple0;
	});
});



// ELEMENT VIEWPORT


function _Browser_getViewportOf(id)
{
	return _Browser_withNode(id, function(node)
	{
		return {
			scene: {
				width: node.scrollWidth,
				height: node.scrollHeight
			},
			viewport: {
				x: node.scrollLeft,
				y: node.scrollTop,
				width: node.clientWidth,
				height: node.clientHeight
			}
		};
	});
}


var _Browser_setViewportOf = F3(function(id, x, y)
{
	return _Browser_withNode(id, function(node)
	{
		node.scrollLeft = x;
		node.scrollTop = y;
		return _Utils_Tuple0;
	});
});



// ELEMENT


function _Browser_getElement(id)
{
	return _Browser_withNode(id, function(node)
	{
		var rect = node.getBoundingClientRect();
		var x = _Browser_window.pageXOffset;
		var y = _Browser_window.pageYOffset;
		return {
			scene: _Browser_getScene(),
			viewport: {
				x: x,
				y: y,
				width: _Browser_doc.documentElement.clientWidth,
				height: _Browser_doc.documentElement.clientHeight
			},
			element: {
				x: x + rect.left,
				y: y + rect.top,
				width: rect.width,
				height: rect.height
			}
		};
	});
}



// LOAD and RELOAD


function _Browser_reload(skipCache)
{
	return A2($elm$core$Task$perform, $elm$core$Basics$never, _Scheduler_binding(function(callback)
	{
		_VirtualDom_doc.location.reload(skipCache);
	}));
}

function _Browser_load(url)
{
	return A2($elm$core$Task$perform, $elm$core$Basics$never, _Scheduler_binding(function(callback)
	{
		try
		{
			_Browser_window.location = url;
		}
		catch(err)
		{
			// Only Firefox can throw a NS_ERROR_MALFORMED_URI exception here.
			// Other browsers reload the page, so let's be consistent about that.
			_VirtualDom_doc.location.reload(false);
		}
	}));
}



// SEND REQUEST

var _Http_toTask = F3(function(router, toTask, request)
{
	return _Scheduler_binding(function(callback)
	{
		function done(response) {
			callback(toTask(request.expect.a(response)));
		}

		var xhr = new XMLHttpRequest();
		xhr.addEventListener('error', function() { done($elm$http$Http$NetworkError_); });
		xhr.addEventListener('timeout', function() { done($elm$http$Http$Timeout_); });
		xhr.addEventListener('load', function() { done(_Http_toResponse(request.expect.b, xhr)); });
		$elm$core$Maybe$isJust(request.tracker) && _Http_track(router, xhr, request.tracker.a);

		try {
			xhr.open(request.method, request.url, true);
		} catch (e) {
			return done($elm$http$Http$BadUrl_(request.url));
		}

		_Http_configureRequest(xhr, request);

		request.body.a && xhr.setRequestHeader('Content-Type', request.body.a);
		xhr.send(request.body.b);

		return function() { xhr.c = true; xhr.abort(); };
	});
});


// CONFIGURE

function _Http_configureRequest(xhr, request)
{
	for (var headers = request.headers; headers.b; headers = headers.b) // WHILE_CONS
	{
		xhr.setRequestHeader(headers.a.a, headers.a.b);
	}
	xhr.timeout = request.timeout.a || 0;
	xhr.responseType = request.expect.d;
	xhr.withCredentials = request.allowCookiesFromOtherDomains;
}


// RESPONSES

function _Http_toResponse(toBody, xhr)
{
	return A2(
		200 <= xhr.status && xhr.status < 300 ? $elm$http$Http$GoodStatus_ : $elm$http$Http$BadStatus_,
		_Http_toMetadata(xhr),
		toBody(xhr.response)
	);
}


// METADATA

function _Http_toMetadata(xhr)
{
	return {
		url: xhr.responseURL,
		statusCode: xhr.status,
		statusText: xhr.statusText,
		headers: _Http_parseHeaders(xhr.getAllResponseHeaders())
	};
}


// HEADERS

function _Http_parseHeaders(rawHeaders)
{
	if (!rawHeaders)
	{
		return $elm$core$Dict$empty;
	}

	var headers = $elm$core$Dict$empty;
	var headerPairs = rawHeaders.split('\r\n');
	for (var i = headerPairs.length; i--; )
	{
		var headerPair = headerPairs[i];
		var index = headerPair.indexOf(': ');
		if (index > 0)
		{
			var key = headerPair.substring(0, index);
			var value = headerPair.substring(index + 2);

			headers = A3($elm$core$Dict$update, key, function(oldValue) {
				return $elm$core$Maybe$Just($elm$core$Maybe$isJust(oldValue)
					? value + ', ' + oldValue.a
					: value
				);
			}, headers);
		}
	}
	return headers;
}


// EXPECT

var _Http_expect = F3(function(type, toBody, toValue)
{
	return {
		$: 0,
		d: type,
		b: toBody,
		a: toValue
	};
});

var _Http_mapExpect = F2(function(func, expect)
{
	return {
		$: 0,
		d: expect.d,
		b: expect.b,
		a: function(x) { return func(expect.a(x)); }
	};
});

function _Http_toDataView(arrayBuffer)
{
	return new DataView(arrayBuffer);
}


// BODY and PARTS

var _Http_emptyBody = { $: 0 };
var _Http_pair = F2(function(a, b) { return { $: 0, a: a, b: b }; });

function _Http_toFormData(parts)
{
	for (var formData = new FormData(); parts.b; parts = parts.b) // WHILE_CONS
	{
		var part = parts.a;
		formData.append(part.a, part.b);
	}
	return formData;
}

var _Http_bytesToBlob = F2(function(mime, bytes)
{
	return new Blob([bytes], { type: mime });
});


// PROGRESS

function _Http_track(router, xhr, tracker)
{
	// TODO check out lengthComputable on loadstart event

	xhr.upload.addEventListener('progress', function(event) {
		if (xhr.c) { return; }
		_Scheduler_rawSpawn(A2($elm$core$Platform$sendToSelf, router, _Utils_Tuple2(tracker, $elm$http$Http$Sending({
			sent: event.loaded,
			size: event.total
		}))));
	});
	xhr.addEventListener('progress', function(event) {
		if (xhr.c) { return; }
		_Scheduler_rawSpawn(A2($elm$core$Platform$sendToSelf, router, _Utils_Tuple2(tracker, $elm$http$Http$Receiving({
			received: event.loaded,
			size: event.lengthComputable ? $elm$core$Maybe$Just(event.total) : $elm$core$Maybe$Nothing
		}))));
	});
}


function _Time_now(millisToPosix)
{
	return _Scheduler_binding(function(callback)
	{
		callback(_Scheduler_succeed(millisToPosix(Date.now())));
	});
}

var _Time_setInterval = F2(function(interval, task)
{
	return _Scheduler_binding(function(callback)
	{
		var id = setInterval(function() { _Scheduler_rawSpawn(task); }, interval);
		return function() { clearInterval(id); };
	});
});

function _Time_here()
{
	return _Scheduler_binding(function(callback)
	{
		callback(_Scheduler_succeed(
			A2($elm$time$Time$customZone, -(new Date().getTimezoneOffset()), _List_Nil)
		));
	});
}


function _Time_getZoneName()
{
	return _Scheduler_binding(function(callback)
	{
		try
		{
			var name = $elm$time$Time$Name(Intl.DateTimeFormat().resolvedOptions().timeZone);
		}
		catch (e)
		{
			var name = $elm$time$Time$Offset(new Date().getTimezoneOffset());
		}
		callback(_Scheduler_succeed(name));
	});
}
var $elm$core$Basics$EQ = {$: 'EQ'};
var $elm$core$Basics$GT = {$: 'GT'};
var $elm$core$Basics$LT = {$: 'LT'};
var $elm$core$List$cons = _List_cons;
var $elm$core$Dict$foldr = F3(
	function (func, acc, t) {
		foldr:
		while (true) {
			if (t.$ === 'RBEmpty_elm_builtin') {
				return acc;
			} else {
				var key = t.b;
				var value = t.c;
				var left = t.d;
				var right = t.e;
				var $temp$func = func,
					$temp$acc = A3(
					func,
					key,
					value,
					A3($elm$core$Dict$foldr, func, acc, right)),
					$temp$t = left;
				func = $temp$func;
				acc = $temp$acc;
				t = $temp$t;
				continue foldr;
			}
		}
	});
var $elm$core$Dict$toList = function (dict) {
	return A3(
		$elm$core$Dict$foldr,
		F3(
			function (key, value, list) {
				return A2(
					$elm$core$List$cons,
					_Utils_Tuple2(key, value),
					list);
			}),
		_List_Nil,
		dict);
};
var $elm$core$Dict$keys = function (dict) {
	return A3(
		$elm$core$Dict$foldr,
		F3(
			function (key, value, keyList) {
				return A2($elm$core$List$cons, key, keyList);
			}),
		_List_Nil,
		dict);
};
var $elm$core$Set$toList = function (_v0) {
	var dict = _v0.a;
	return $elm$core$Dict$keys(dict);
};
var $elm$core$Elm$JsArray$foldr = _JsArray_foldr;
var $elm$core$Array$foldr = F3(
	function (func, baseCase, _v0) {
		var tree = _v0.c;
		var tail = _v0.d;
		var helper = F2(
			function (node, acc) {
				if (node.$ === 'SubTree') {
					var subTree = node.a;
					return A3($elm$core$Elm$JsArray$foldr, helper, acc, subTree);
				} else {
					var values = node.a;
					return A3($elm$core$Elm$JsArray$foldr, func, acc, values);
				}
			});
		return A3(
			$elm$core$Elm$JsArray$foldr,
			helper,
			A3($elm$core$Elm$JsArray$foldr, func, baseCase, tail),
			tree);
	});
var $elm$core$Array$toList = function (array) {
	return A3($elm$core$Array$foldr, $elm$core$List$cons, _List_Nil, array);
};
var $elm$core$Result$Err = function (a) {
	return {$: 'Err', a: a};
};
var $elm$json$Json$Decode$Failure = F2(
	function (a, b) {
		return {$: 'Failure', a: a, b: b};
	});
var $elm$json$Json$Decode$Field = F2(
	function (a, b) {
		return {$: 'Field', a: a, b: b};
	});
var $elm$json$Json$Decode$Index = F2(
	function (a, b) {
		return {$: 'Index', a: a, b: b};
	});
var $elm$core$Result$Ok = function (a) {
	return {$: 'Ok', a: a};
};
var $elm$json$Json$Decode$OneOf = function (a) {
	return {$: 'OneOf', a: a};
};
var $elm$core$Basics$False = {$: 'False'};
var $elm$core$Basics$add = _Basics_add;
var $elm$core$Maybe$Just = function (a) {
	return {$: 'Just', a: a};
};
var $elm$core$Maybe$Nothing = {$: 'Nothing'};
var $elm$core$String$all = _String_all;
var $elm$core$Basics$and = _Basics_and;
var $elm$core$Basics$append = _Utils_append;
var $elm$json$Json$Encode$encode = _Json_encode;
var $elm$core$String$fromInt = _String_fromNumber;
var $elm$core$String$join = F2(
	function (sep, chunks) {
		return A2(
			_String_join,
			sep,
			_List_toArray(chunks));
	});
var $elm$core$String$split = F2(
	function (sep, string) {
		return _List_fromArray(
			A2(_String_split, sep, string));
	});
var $elm$json$Json$Decode$indent = function (str) {
	return A2(
		$elm$core$String$join,
		'\n    ',
		A2($elm$core$String$split, '\n', str));
};
var $elm$core$List$foldl = F3(
	function (func, acc, list) {
		foldl:
		while (true) {
			if (!list.b) {
				return acc;
			} else {
				var x = list.a;
				var xs = list.b;
				var $temp$func = func,
					$temp$acc = A2(func, x, acc),
					$temp$list = xs;
				func = $temp$func;
				acc = $temp$acc;
				list = $temp$list;
				continue foldl;
			}
		}
	});
var $elm$core$List$length = function (xs) {
	return A3(
		$elm$core$List$foldl,
		F2(
			function (_v0, i) {
				return i + 1;
			}),
		0,
		xs);
};
var $elm$core$List$map2 = _List_map2;
var $elm$core$Basics$le = _Utils_le;
var $elm$core$Basics$sub = _Basics_sub;
var $elm$core$List$rangeHelp = F3(
	function (lo, hi, list) {
		rangeHelp:
		while (true) {
			if (_Utils_cmp(lo, hi) < 1) {
				var $temp$lo = lo,
					$temp$hi = hi - 1,
					$temp$list = A2($elm$core$List$cons, hi, list);
				lo = $temp$lo;
				hi = $temp$hi;
				list = $temp$list;
				continue rangeHelp;
			} else {
				return list;
			}
		}
	});
var $elm$core$List$range = F2(
	function (lo, hi) {
		return A3($elm$core$List$rangeHelp, lo, hi, _List_Nil);
	});
var $elm$core$List$indexedMap = F2(
	function (f, xs) {
		return A3(
			$elm$core$List$map2,
			f,
			A2(
				$elm$core$List$range,
				0,
				$elm$core$List$length(xs) - 1),
			xs);
	});
var $elm$core$Char$toCode = _Char_toCode;
var $elm$core$Char$isLower = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return (97 <= code) && (code <= 122);
};
var $elm$core$Char$isUpper = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return (code <= 90) && (65 <= code);
};
var $elm$core$Basics$or = _Basics_or;
var $elm$core$Char$isAlpha = function (_char) {
	return $elm$core$Char$isLower(_char) || $elm$core$Char$isUpper(_char);
};
var $elm$core$Char$isDigit = function (_char) {
	var code = $elm$core$Char$toCode(_char);
	return (code <= 57) && (48 <= code);
};
var $elm$core$Char$isAlphaNum = function (_char) {
	return $elm$core$Char$isLower(_char) || ($elm$core$Char$isUpper(_char) || $elm$core$Char$isDigit(_char));
};
var $elm$core$List$reverse = function (list) {
	return A3($elm$core$List$foldl, $elm$core$List$cons, _List_Nil, list);
};
var $elm$core$String$uncons = _String_uncons;
var $elm$json$Json$Decode$errorOneOf = F2(
	function (i, error) {
		return '\n\n(' + ($elm$core$String$fromInt(i + 1) + (') ' + $elm$json$Json$Decode$indent(
			$elm$json$Json$Decode$errorToString(error))));
	});
var $elm$json$Json$Decode$errorToString = function (error) {
	return A2($elm$json$Json$Decode$errorToStringHelp, error, _List_Nil);
};
var $elm$json$Json$Decode$errorToStringHelp = F2(
	function (error, context) {
		errorToStringHelp:
		while (true) {
			switch (error.$) {
				case 'Field':
					var f = error.a;
					var err = error.b;
					var isSimple = function () {
						var _v1 = $elm$core$String$uncons(f);
						if (_v1.$ === 'Nothing') {
							return false;
						} else {
							var _v2 = _v1.a;
							var _char = _v2.a;
							var rest = _v2.b;
							return $elm$core$Char$isAlpha(_char) && A2($elm$core$String$all, $elm$core$Char$isAlphaNum, rest);
						}
					}();
					var fieldName = isSimple ? ('.' + f) : ('[\'' + (f + '\']'));
					var $temp$error = err,
						$temp$context = A2($elm$core$List$cons, fieldName, context);
					error = $temp$error;
					context = $temp$context;
					continue errorToStringHelp;
				case 'Index':
					var i = error.a;
					var err = error.b;
					var indexName = '[' + ($elm$core$String$fromInt(i) + ']');
					var $temp$error = err,
						$temp$context = A2($elm$core$List$cons, indexName, context);
					error = $temp$error;
					context = $temp$context;
					continue errorToStringHelp;
				case 'OneOf':
					var errors = error.a;
					if (!errors.b) {
						return 'Ran into a Json.Decode.oneOf with no possibilities' + function () {
							if (!context.b) {
								return '!';
							} else {
								return ' at json' + A2(
									$elm$core$String$join,
									'',
									$elm$core$List$reverse(context));
							}
						}();
					} else {
						if (!errors.b.b) {
							var err = errors.a;
							var $temp$error = err,
								$temp$context = context;
							error = $temp$error;
							context = $temp$context;
							continue errorToStringHelp;
						} else {
							var starter = function () {
								if (!context.b) {
									return 'Json.Decode.oneOf';
								} else {
									return 'The Json.Decode.oneOf at json' + A2(
										$elm$core$String$join,
										'',
										$elm$core$List$reverse(context));
								}
							}();
							var introduction = starter + (' failed in the following ' + ($elm$core$String$fromInt(
								$elm$core$List$length(errors)) + ' ways:'));
							return A2(
								$elm$core$String$join,
								'\n\n',
								A2(
									$elm$core$List$cons,
									introduction,
									A2($elm$core$List$indexedMap, $elm$json$Json$Decode$errorOneOf, errors)));
						}
					}
				default:
					var msg = error.a;
					var json = error.b;
					var introduction = function () {
						if (!context.b) {
							return 'Problem with the given value:\n\n';
						} else {
							return 'Problem with the value at json' + (A2(
								$elm$core$String$join,
								'',
								$elm$core$List$reverse(context)) + ':\n\n    ');
						}
					}();
					return introduction + ($elm$json$Json$Decode$indent(
						A2($elm$json$Json$Encode$encode, 4, json)) + ('\n\n' + msg));
			}
		}
	});
var $elm$core$Array$branchFactor = 32;
var $elm$core$Array$Array_elm_builtin = F4(
	function (a, b, c, d) {
		return {$: 'Array_elm_builtin', a: a, b: b, c: c, d: d};
	});
var $elm$core$Elm$JsArray$empty = _JsArray_empty;
var $elm$core$Basics$ceiling = _Basics_ceiling;
var $elm$core$Basics$fdiv = _Basics_fdiv;
var $elm$core$Basics$logBase = F2(
	function (base, number) {
		return _Basics_log(number) / _Basics_log(base);
	});
var $elm$core$Basics$toFloat = _Basics_toFloat;
var $elm$core$Array$shiftStep = $elm$core$Basics$ceiling(
	A2($elm$core$Basics$logBase, 2, $elm$core$Array$branchFactor));
var $elm$core$Array$empty = A4($elm$core$Array$Array_elm_builtin, 0, $elm$core$Array$shiftStep, $elm$core$Elm$JsArray$empty, $elm$core$Elm$JsArray$empty);
var $elm$core$Elm$JsArray$initialize = _JsArray_initialize;
var $elm$core$Array$Leaf = function (a) {
	return {$: 'Leaf', a: a};
};
var $elm$core$Basics$apL = F2(
	function (f, x) {
		return f(x);
	});
var $elm$core$Basics$apR = F2(
	function (x, f) {
		return f(x);
	});
var $elm$core$Basics$eq = _Utils_equal;
var $elm$core$Basics$floor = _Basics_floor;
var $elm$core$Elm$JsArray$length = _JsArray_length;
var $elm$core$Basics$gt = _Utils_gt;
var $elm$core$Basics$max = F2(
	function (x, y) {
		return (_Utils_cmp(x, y) > 0) ? x : y;
	});
var $elm$core$Basics$mul = _Basics_mul;
var $elm$core$Array$SubTree = function (a) {
	return {$: 'SubTree', a: a};
};
var $elm$core$Elm$JsArray$initializeFromList = _JsArray_initializeFromList;
var $elm$core$Array$compressNodes = F2(
	function (nodes, acc) {
		compressNodes:
		while (true) {
			var _v0 = A2($elm$core$Elm$JsArray$initializeFromList, $elm$core$Array$branchFactor, nodes);
			var node = _v0.a;
			var remainingNodes = _v0.b;
			var newAcc = A2(
				$elm$core$List$cons,
				$elm$core$Array$SubTree(node),
				acc);
			if (!remainingNodes.b) {
				return $elm$core$List$reverse(newAcc);
			} else {
				var $temp$nodes = remainingNodes,
					$temp$acc = newAcc;
				nodes = $temp$nodes;
				acc = $temp$acc;
				continue compressNodes;
			}
		}
	});
var $elm$core$Tuple$first = function (_v0) {
	var x = _v0.a;
	return x;
};
var $elm$core$Array$treeFromBuilder = F2(
	function (nodeList, nodeListSize) {
		treeFromBuilder:
		while (true) {
			var newNodeSize = $elm$core$Basics$ceiling(nodeListSize / $elm$core$Array$branchFactor);
			if (newNodeSize === 1) {
				return A2($elm$core$Elm$JsArray$initializeFromList, $elm$core$Array$branchFactor, nodeList).a;
			} else {
				var $temp$nodeList = A2($elm$core$Array$compressNodes, nodeList, _List_Nil),
					$temp$nodeListSize = newNodeSize;
				nodeList = $temp$nodeList;
				nodeListSize = $temp$nodeListSize;
				continue treeFromBuilder;
			}
		}
	});
var $elm$core$Array$builderToArray = F2(
	function (reverseNodeList, builder) {
		if (!builder.nodeListSize) {
			return A4(
				$elm$core$Array$Array_elm_builtin,
				$elm$core$Elm$JsArray$length(builder.tail),
				$elm$core$Array$shiftStep,
				$elm$core$Elm$JsArray$empty,
				builder.tail);
		} else {
			var treeLen = builder.nodeListSize * $elm$core$Array$branchFactor;
			var depth = $elm$core$Basics$floor(
				A2($elm$core$Basics$logBase, $elm$core$Array$branchFactor, treeLen - 1));
			var correctNodeList = reverseNodeList ? $elm$core$List$reverse(builder.nodeList) : builder.nodeList;
			var tree = A2($elm$core$Array$treeFromBuilder, correctNodeList, builder.nodeListSize);
			return A4(
				$elm$core$Array$Array_elm_builtin,
				$elm$core$Elm$JsArray$length(builder.tail) + treeLen,
				A2($elm$core$Basics$max, 5, depth * $elm$core$Array$shiftStep),
				tree,
				builder.tail);
		}
	});
var $elm$core$Basics$idiv = _Basics_idiv;
var $elm$core$Basics$lt = _Utils_lt;
var $elm$core$Array$initializeHelp = F5(
	function (fn, fromIndex, len, nodeList, tail) {
		initializeHelp:
		while (true) {
			if (fromIndex < 0) {
				return A2(
					$elm$core$Array$builderToArray,
					false,
					{nodeList: nodeList, nodeListSize: (len / $elm$core$Array$branchFactor) | 0, tail: tail});
			} else {
				var leaf = $elm$core$Array$Leaf(
					A3($elm$core$Elm$JsArray$initialize, $elm$core$Array$branchFactor, fromIndex, fn));
				var $temp$fn = fn,
					$temp$fromIndex = fromIndex - $elm$core$Array$branchFactor,
					$temp$len = len,
					$temp$nodeList = A2($elm$core$List$cons, leaf, nodeList),
					$temp$tail = tail;
				fn = $temp$fn;
				fromIndex = $temp$fromIndex;
				len = $temp$len;
				nodeList = $temp$nodeList;
				tail = $temp$tail;
				continue initializeHelp;
			}
		}
	});
var $elm$core$Basics$remainderBy = _Basics_remainderBy;
var $elm$core$Array$initialize = F2(
	function (len, fn) {
		if (len <= 0) {
			return $elm$core$Array$empty;
		} else {
			var tailLen = len % $elm$core$Array$branchFactor;
			var tail = A3($elm$core$Elm$JsArray$initialize, tailLen, len - tailLen, fn);
			var initialFromIndex = (len - tailLen) - $elm$core$Array$branchFactor;
			return A5($elm$core$Array$initializeHelp, fn, initialFromIndex, len, _List_Nil, tail);
		}
	});
var $elm$core$Basics$True = {$: 'True'};
var $elm$core$Result$isOk = function (result) {
	if (result.$ === 'Ok') {
		return true;
	} else {
		return false;
	}
};
var $elm$json$Json$Decode$map = _Json_map1;
var $elm$json$Json$Decode$map2 = _Json_map2;
var $elm$json$Json$Decode$succeed = _Json_succeed;
var $elm$virtual_dom$VirtualDom$toHandlerInt = function (handler) {
	switch (handler.$) {
		case 'Normal':
			return 0;
		case 'MayStopPropagation':
			return 1;
		case 'MayPreventDefault':
			return 2;
		default:
			return 3;
	}
};
var $elm$browser$Browser$External = function (a) {
	return {$: 'External', a: a};
};
var $elm$browser$Browser$Internal = function (a) {
	return {$: 'Internal', a: a};
};
var $elm$core$Basics$identity = function (x) {
	return x;
};
var $elm$browser$Browser$Dom$NotFound = function (a) {
	return {$: 'NotFound', a: a};
};
var $elm$url$Url$Http = {$: 'Http'};
var $elm$url$Url$Https = {$: 'Https'};
var $elm$url$Url$Url = F6(
	function (protocol, host, port_, path, query, fragment) {
		return {fragment: fragment, host: host, path: path, port_: port_, protocol: protocol, query: query};
	});
var $elm$core$String$contains = _String_contains;
var $elm$core$String$length = _String_length;
var $elm$core$String$slice = _String_slice;
var $elm$core$String$dropLeft = F2(
	function (n, string) {
		return (n < 1) ? string : A3(
			$elm$core$String$slice,
			n,
			$elm$core$String$length(string),
			string);
	});
var $elm$core$String$indexes = _String_indexes;
var $elm$core$String$isEmpty = function (string) {
	return string === '';
};
var $elm$core$String$left = F2(
	function (n, string) {
		return (n < 1) ? '' : A3($elm$core$String$slice, 0, n, string);
	});
var $elm$core$String$toInt = _String_toInt;
var $elm$url$Url$chompBeforePath = F5(
	function (protocol, path, params, frag, str) {
		if ($elm$core$String$isEmpty(str) || A2($elm$core$String$contains, '@', str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, ':', str);
			if (!_v0.b) {
				return $elm$core$Maybe$Just(
					A6($elm$url$Url$Url, protocol, str, $elm$core$Maybe$Nothing, path, params, frag));
			} else {
				if (!_v0.b.b) {
					var i = _v0.a;
					var _v1 = $elm$core$String$toInt(
						A2($elm$core$String$dropLeft, i + 1, str));
					if (_v1.$ === 'Nothing') {
						return $elm$core$Maybe$Nothing;
					} else {
						var port_ = _v1;
						return $elm$core$Maybe$Just(
							A6(
								$elm$url$Url$Url,
								protocol,
								A2($elm$core$String$left, i, str),
								port_,
								path,
								params,
								frag));
					}
				} else {
					return $elm$core$Maybe$Nothing;
				}
			}
		}
	});
var $elm$url$Url$chompBeforeQuery = F4(
	function (protocol, params, frag, str) {
		if ($elm$core$String$isEmpty(str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, '/', str);
			if (!_v0.b) {
				return A5($elm$url$Url$chompBeforePath, protocol, '/', params, frag, str);
			} else {
				var i = _v0.a;
				return A5(
					$elm$url$Url$chompBeforePath,
					protocol,
					A2($elm$core$String$dropLeft, i, str),
					params,
					frag,
					A2($elm$core$String$left, i, str));
			}
		}
	});
var $elm$url$Url$chompBeforeFragment = F3(
	function (protocol, frag, str) {
		if ($elm$core$String$isEmpty(str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, '?', str);
			if (!_v0.b) {
				return A4($elm$url$Url$chompBeforeQuery, protocol, $elm$core$Maybe$Nothing, frag, str);
			} else {
				var i = _v0.a;
				return A4(
					$elm$url$Url$chompBeforeQuery,
					protocol,
					$elm$core$Maybe$Just(
						A2($elm$core$String$dropLeft, i + 1, str)),
					frag,
					A2($elm$core$String$left, i, str));
			}
		}
	});
var $elm$url$Url$chompAfterProtocol = F2(
	function (protocol, str) {
		if ($elm$core$String$isEmpty(str)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v0 = A2($elm$core$String$indexes, '#', str);
			if (!_v0.b) {
				return A3($elm$url$Url$chompBeforeFragment, protocol, $elm$core$Maybe$Nothing, str);
			} else {
				var i = _v0.a;
				return A3(
					$elm$url$Url$chompBeforeFragment,
					protocol,
					$elm$core$Maybe$Just(
						A2($elm$core$String$dropLeft, i + 1, str)),
					A2($elm$core$String$left, i, str));
			}
		}
	});
var $elm$core$String$startsWith = _String_startsWith;
var $elm$url$Url$fromString = function (str) {
	return A2($elm$core$String$startsWith, 'http://', str) ? A2(
		$elm$url$Url$chompAfterProtocol,
		$elm$url$Url$Http,
		A2($elm$core$String$dropLeft, 7, str)) : (A2($elm$core$String$startsWith, 'https://', str) ? A2(
		$elm$url$Url$chompAfterProtocol,
		$elm$url$Url$Https,
		A2($elm$core$String$dropLeft, 8, str)) : $elm$core$Maybe$Nothing);
};
var $elm$core$Basics$never = function (_v0) {
	never:
	while (true) {
		var nvr = _v0.a;
		var $temp$_v0 = nvr;
		_v0 = $temp$_v0;
		continue never;
	}
};
var $elm$core$Task$Perform = function (a) {
	return {$: 'Perform', a: a};
};
var $elm$core$Task$succeed = _Scheduler_succeed;
var $elm$core$Task$init = $elm$core$Task$succeed(_Utils_Tuple0);
var $elm$core$List$foldrHelper = F4(
	function (fn, acc, ctr, ls) {
		if (!ls.b) {
			return acc;
		} else {
			var a = ls.a;
			var r1 = ls.b;
			if (!r1.b) {
				return A2(fn, a, acc);
			} else {
				var b = r1.a;
				var r2 = r1.b;
				if (!r2.b) {
					return A2(
						fn,
						a,
						A2(fn, b, acc));
				} else {
					var c = r2.a;
					var r3 = r2.b;
					if (!r3.b) {
						return A2(
							fn,
							a,
							A2(
								fn,
								b,
								A2(fn, c, acc)));
					} else {
						var d = r3.a;
						var r4 = r3.b;
						var res = (ctr > 500) ? A3(
							$elm$core$List$foldl,
							fn,
							acc,
							$elm$core$List$reverse(r4)) : A4($elm$core$List$foldrHelper, fn, acc, ctr + 1, r4);
						return A2(
							fn,
							a,
							A2(
								fn,
								b,
								A2(
									fn,
									c,
									A2(fn, d, res))));
					}
				}
			}
		}
	});
var $elm$core$List$foldr = F3(
	function (fn, acc, ls) {
		return A4($elm$core$List$foldrHelper, fn, acc, 0, ls);
	});
var $elm$core$List$map = F2(
	function (f, xs) {
		return A3(
			$elm$core$List$foldr,
			F2(
				function (x, acc) {
					return A2(
						$elm$core$List$cons,
						f(x),
						acc);
				}),
			_List_Nil,
			xs);
	});
var $elm$core$Task$andThen = _Scheduler_andThen;
var $elm$core$Task$map = F2(
	function (func, taskA) {
		return A2(
			$elm$core$Task$andThen,
			function (a) {
				return $elm$core$Task$succeed(
					func(a));
			},
			taskA);
	});
var $elm$core$Task$map2 = F3(
	function (func, taskA, taskB) {
		return A2(
			$elm$core$Task$andThen,
			function (a) {
				return A2(
					$elm$core$Task$andThen,
					function (b) {
						return $elm$core$Task$succeed(
							A2(func, a, b));
					},
					taskB);
			},
			taskA);
	});
var $elm$core$Task$sequence = function (tasks) {
	return A3(
		$elm$core$List$foldr,
		$elm$core$Task$map2($elm$core$List$cons),
		$elm$core$Task$succeed(_List_Nil),
		tasks);
};
var $elm$core$Platform$sendToApp = _Platform_sendToApp;
var $elm$core$Task$spawnCmd = F2(
	function (router, _v0) {
		var task = _v0.a;
		return _Scheduler_spawn(
			A2(
				$elm$core$Task$andThen,
				$elm$core$Platform$sendToApp(router),
				task));
	});
var $elm$core$Task$onEffects = F3(
	function (router, commands, state) {
		return A2(
			$elm$core$Task$map,
			function (_v0) {
				return _Utils_Tuple0;
			},
			$elm$core$Task$sequence(
				A2(
					$elm$core$List$map,
					$elm$core$Task$spawnCmd(router),
					commands)));
	});
var $elm$core$Task$onSelfMsg = F3(
	function (_v0, _v1, _v2) {
		return $elm$core$Task$succeed(_Utils_Tuple0);
	});
var $elm$core$Task$cmdMap = F2(
	function (tagger, _v0) {
		var task = _v0.a;
		return $elm$core$Task$Perform(
			A2($elm$core$Task$map, tagger, task));
	});
_Platform_effectManagers['Task'] = _Platform_createManager($elm$core$Task$init, $elm$core$Task$onEffects, $elm$core$Task$onSelfMsg, $elm$core$Task$cmdMap);
var $elm$core$Task$command = _Platform_leaf('Task');
var $elm$core$Task$perform = F2(
	function (toMessage, task) {
		return $elm$core$Task$command(
			$elm$core$Task$Perform(
				A2($elm$core$Task$map, toMessage, task)));
	});
var $elm$browser$Browser$element = _Browser_element;
var $author$project$Lab$CatalogLoading = {$: 'CatalogLoading'};
var $elm$core$Dict$RBEmpty_elm_builtin = {$: 'RBEmpty_elm_builtin'};
var $elm$core$Dict$empty = $elm$core$Dict$RBEmpty_elm_builtin;
var $elm$core$Platform$Cmd$batch = _Platform_batch;
var $elm$core$Platform$Cmd$none = $elm$core$Platform$Cmd$batch(_List_Nil);
var $author$project$Lab$init = function (_v0) {
	return _Utils_Tuple2(
		{annotations: $elm$core$Dict$empty, catalog: $author$project$Lab$CatalogLoading, finished: false, panels: $elm$core$Dict$empty, sessionId: $elm$core$Maybe$Nothing, started: false, userName: ''},
		$elm$core$Platform$Cmd$none);
};
var $author$project$Lab$PlayMsg = F2(
	function (a, b) {
		return {$: 'PlayMsg', a: a, b: b};
	});
var $elm$core$Platform$Sub$batch = _Platform_batch;
var $elm$core$List$maybeCons = F3(
	function (f, mx, xs) {
		var _v0 = f(mx);
		if (_v0.$ === 'Just') {
			var x = _v0.a;
			return A2($elm$core$List$cons, x, xs);
		} else {
			return xs;
		}
	});
var $elm$core$List$filterMap = F2(
	function (f, xs) {
		return A3(
			$elm$core$List$foldr,
			$elm$core$List$maybeCons(f),
			_List_Nil,
			xs);
	});
var $elm$core$Platform$Sub$map = _Platform_map;
var $author$project$Main$Msg$ReplayFrame = function (a) {
	return {$: 'ReplayFrame', a: a};
};
var $author$project$Main$Msg$MouseMove = F2(
	function (a, b) {
		return {$: 'MouseMove', a: a, b: b};
	});
var $elm$json$Json$Decode$field = _Json_decodeField;
var $elm$json$Json$Decode$float = _Json_decodeFloat;
var $elm$core$Basics$round = _Basics_round;
var $author$project$Main$Gesture$pointDecoder = A3(
	$elm$json$Json$Decode$map2,
	F2(
		function (x, y) {
			return {
				x: $elm$core$Basics$round(x),
				y: $elm$core$Basics$round(y)
			};
		}),
	A2($elm$json$Json$Decode$field, 'clientX', $elm$json$Json$Decode$float),
	A2($elm$json$Json$Decode$field, 'clientY', $elm$json$Json$Decode$float));
var $author$project$Main$Play$mouseMoveDecoder = A3(
	$elm$json$Json$Decode$map2,
	$author$project$Main$Msg$MouseMove,
	$author$project$Main$Gesture$pointDecoder,
	A2($elm$json$Json$Decode$field, 'timeStamp', $elm$json$Json$Decode$float));
var $author$project$Main$Msg$MouseUp = F2(
	function (a, b) {
		return {$: 'MouseUp', a: a, b: b};
	});
var $author$project$Main$Play$mouseUpDecoder = A3(
	$elm$json$Json$Decode$map2,
	$author$project$Main$Msg$MouseUp,
	$author$project$Main$Gesture$pointDecoder,
	A2($elm$json$Json$Decode$field, 'timeStamp', $elm$json$Json$Decode$float));
var $elm$browser$Browser$AnimationManager$Time = function (a) {
	return {$: 'Time', a: a};
};
var $elm$browser$Browser$AnimationManager$State = F3(
	function (subs, request, oldTime) {
		return {oldTime: oldTime, request: request, subs: subs};
	});
var $elm$browser$Browser$AnimationManager$init = $elm$core$Task$succeed(
	A3($elm$browser$Browser$AnimationManager$State, _List_Nil, $elm$core$Maybe$Nothing, 0));
var $elm$core$Process$kill = _Scheduler_kill;
var $elm$browser$Browser$AnimationManager$now = _Browser_now(_Utils_Tuple0);
var $elm$browser$Browser$AnimationManager$rAF = _Browser_rAF(_Utils_Tuple0);
var $elm$core$Platform$sendToSelf = _Platform_sendToSelf;
var $elm$core$Process$spawn = _Scheduler_spawn;
var $elm$browser$Browser$AnimationManager$onEffects = F3(
	function (router, subs, _v0) {
		var request = _v0.request;
		var oldTime = _v0.oldTime;
		var _v1 = _Utils_Tuple2(request, subs);
		if (_v1.a.$ === 'Nothing') {
			if (!_v1.b.b) {
				var _v2 = _v1.a;
				return $elm$browser$Browser$AnimationManager$init;
			} else {
				var _v4 = _v1.a;
				return A2(
					$elm$core$Task$andThen,
					function (pid) {
						return A2(
							$elm$core$Task$andThen,
							function (time) {
								return $elm$core$Task$succeed(
									A3(
										$elm$browser$Browser$AnimationManager$State,
										subs,
										$elm$core$Maybe$Just(pid),
										time));
							},
							$elm$browser$Browser$AnimationManager$now);
					},
					$elm$core$Process$spawn(
						A2(
							$elm$core$Task$andThen,
							$elm$core$Platform$sendToSelf(router),
							$elm$browser$Browser$AnimationManager$rAF)));
			}
		} else {
			if (!_v1.b.b) {
				var pid = _v1.a.a;
				return A2(
					$elm$core$Task$andThen,
					function (_v3) {
						return $elm$browser$Browser$AnimationManager$init;
					},
					$elm$core$Process$kill(pid));
			} else {
				return $elm$core$Task$succeed(
					A3($elm$browser$Browser$AnimationManager$State, subs, request, oldTime));
			}
		}
	});
var $elm$time$Time$Posix = function (a) {
	return {$: 'Posix', a: a};
};
var $elm$time$Time$millisToPosix = $elm$time$Time$Posix;
var $elm$browser$Browser$AnimationManager$onSelfMsg = F3(
	function (router, newTime, _v0) {
		var subs = _v0.subs;
		var oldTime = _v0.oldTime;
		var send = function (sub) {
			if (sub.$ === 'Time') {
				var tagger = sub.a;
				return A2(
					$elm$core$Platform$sendToApp,
					router,
					tagger(
						$elm$time$Time$millisToPosix(newTime)));
			} else {
				var tagger = sub.a;
				return A2(
					$elm$core$Platform$sendToApp,
					router,
					tagger(newTime - oldTime));
			}
		};
		return A2(
			$elm$core$Task$andThen,
			function (pid) {
				return A2(
					$elm$core$Task$andThen,
					function (_v1) {
						return $elm$core$Task$succeed(
							A3(
								$elm$browser$Browser$AnimationManager$State,
								subs,
								$elm$core$Maybe$Just(pid),
								newTime));
					},
					$elm$core$Task$sequence(
						A2($elm$core$List$map, send, subs)));
			},
			$elm$core$Process$spawn(
				A2(
					$elm$core$Task$andThen,
					$elm$core$Platform$sendToSelf(router),
					$elm$browser$Browser$AnimationManager$rAF)));
	});
var $elm$browser$Browser$AnimationManager$Delta = function (a) {
	return {$: 'Delta', a: a};
};
var $elm$core$Basics$composeL = F3(
	function (g, f, x) {
		return g(
			f(x));
	});
var $elm$browser$Browser$AnimationManager$subMap = F2(
	function (func, sub) {
		if (sub.$ === 'Time') {
			var tagger = sub.a;
			return $elm$browser$Browser$AnimationManager$Time(
				A2($elm$core$Basics$composeL, func, tagger));
		} else {
			var tagger = sub.a;
			return $elm$browser$Browser$AnimationManager$Delta(
				A2($elm$core$Basics$composeL, func, tagger));
		}
	});
_Platform_effectManagers['Browser.AnimationManager'] = _Platform_createManager($elm$browser$Browser$AnimationManager$init, $elm$browser$Browser$AnimationManager$onEffects, $elm$browser$Browser$AnimationManager$onSelfMsg, 0, $elm$browser$Browser$AnimationManager$subMap);
var $elm$browser$Browser$AnimationManager$subscription = _Platform_leaf('Browser.AnimationManager');
var $elm$browser$Browser$AnimationManager$onAnimationFrame = function (tagger) {
	return $elm$browser$Browser$AnimationManager$subscription(
		$elm$browser$Browser$AnimationManager$Time(tagger));
};
var $elm$browser$Browser$Events$onAnimationFrame = $elm$browser$Browser$AnimationManager$onAnimationFrame;
var $elm$browser$Browser$Events$Document = {$: 'Document'};
var $elm$browser$Browser$Events$MySub = F3(
	function (a, b, c) {
		return {$: 'MySub', a: a, b: b, c: c};
	});
var $elm$browser$Browser$Events$State = F2(
	function (subs, pids) {
		return {pids: pids, subs: subs};
	});
var $elm$browser$Browser$Events$init = $elm$core$Task$succeed(
	A2($elm$browser$Browser$Events$State, _List_Nil, $elm$core$Dict$empty));
var $elm$browser$Browser$Events$nodeToKey = function (node) {
	if (node.$ === 'Document') {
		return 'd_';
	} else {
		return 'w_';
	}
};
var $elm$browser$Browser$Events$addKey = function (sub) {
	var node = sub.a;
	var name = sub.b;
	return _Utils_Tuple2(
		_Utils_ap(
			$elm$browser$Browser$Events$nodeToKey(node),
			name),
		sub);
};
var $elm$core$Dict$Black = {$: 'Black'};
var $elm$core$Dict$RBNode_elm_builtin = F5(
	function (a, b, c, d, e) {
		return {$: 'RBNode_elm_builtin', a: a, b: b, c: c, d: d, e: e};
	});
var $elm$core$Dict$Red = {$: 'Red'};
var $elm$core$Dict$balance = F5(
	function (color, key, value, left, right) {
		if ((right.$ === 'RBNode_elm_builtin') && (right.a.$ === 'Red')) {
			var _v1 = right.a;
			var rK = right.b;
			var rV = right.c;
			var rLeft = right.d;
			var rRight = right.e;
			if ((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Red')) {
				var _v3 = left.a;
				var lK = left.b;
				var lV = left.c;
				var lLeft = left.d;
				var lRight = left.e;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Red,
					key,
					value,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					color,
					rK,
					rV,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, key, value, left, rLeft),
					rRight);
			}
		} else {
			if ((((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Red')) && (left.d.$ === 'RBNode_elm_builtin')) && (left.d.a.$ === 'Red')) {
				var _v5 = left.a;
				var lK = left.b;
				var lV = left.c;
				var _v6 = left.d;
				var _v7 = _v6.a;
				var llK = _v6.b;
				var llV = _v6.c;
				var llLeft = _v6.d;
				var llRight = _v6.e;
				var lRight = left.e;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Red,
					lK,
					lV,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, llK, llV, llLeft, llRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, key, value, lRight, right));
			} else {
				return A5($elm$core$Dict$RBNode_elm_builtin, color, key, value, left, right);
			}
		}
	});
var $elm$core$Basics$compare = _Utils_compare;
var $elm$core$Dict$insertHelp = F3(
	function (key, value, dict) {
		if (dict.$ === 'RBEmpty_elm_builtin') {
			return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, key, value, $elm$core$Dict$RBEmpty_elm_builtin, $elm$core$Dict$RBEmpty_elm_builtin);
		} else {
			var nColor = dict.a;
			var nKey = dict.b;
			var nValue = dict.c;
			var nLeft = dict.d;
			var nRight = dict.e;
			var _v1 = A2($elm$core$Basics$compare, key, nKey);
			switch (_v1.$) {
				case 'LT':
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						A3($elm$core$Dict$insertHelp, key, value, nLeft),
						nRight);
				case 'EQ':
					return A5($elm$core$Dict$RBNode_elm_builtin, nColor, nKey, value, nLeft, nRight);
				default:
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						nLeft,
						A3($elm$core$Dict$insertHelp, key, value, nRight));
			}
		}
	});
var $elm$core$Dict$insert = F3(
	function (key, value, dict) {
		var _v0 = A3($elm$core$Dict$insertHelp, key, value, dict);
		if ((_v0.$ === 'RBNode_elm_builtin') && (_v0.a.$ === 'Red')) {
			var _v1 = _v0.a;
			var k = _v0.b;
			var v = _v0.c;
			var l = _v0.d;
			var r = _v0.e;
			return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, k, v, l, r);
		} else {
			var x = _v0;
			return x;
		}
	});
var $elm$core$Dict$fromList = function (assocs) {
	return A3(
		$elm$core$List$foldl,
		F2(
			function (_v0, dict) {
				var key = _v0.a;
				var value = _v0.b;
				return A3($elm$core$Dict$insert, key, value, dict);
			}),
		$elm$core$Dict$empty,
		assocs);
};
var $elm$core$Dict$foldl = F3(
	function (func, acc, dict) {
		foldl:
		while (true) {
			if (dict.$ === 'RBEmpty_elm_builtin') {
				return acc;
			} else {
				var key = dict.b;
				var value = dict.c;
				var left = dict.d;
				var right = dict.e;
				var $temp$func = func,
					$temp$acc = A3(
					func,
					key,
					value,
					A3($elm$core$Dict$foldl, func, acc, left)),
					$temp$dict = right;
				func = $temp$func;
				acc = $temp$acc;
				dict = $temp$dict;
				continue foldl;
			}
		}
	});
var $elm$core$Dict$merge = F6(
	function (leftStep, bothStep, rightStep, leftDict, rightDict, initialResult) {
		var stepState = F3(
			function (rKey, rValue, _v0) {
				stepState:
				while (true) {
					var list = _v0.a;
					var result = _v0.b;
					if (!list.b) {
						return _Utils_Tuple2(
							list,
							A3(rightStep, rKey, rValue, result));
					} else {
						var _v2 = list.a;
						var lKey = _v2.a;
						var lValue = _v2.b;
						var rest = list.b;
						if (_Utils_cmp(lKey, rKey) < 0) {
							var $temp$rKey = rKey,
								$temp$rValue = rValue,
								$temp$_v0 = _Utils_Tuple2(
								rest,
								A3(leftStep, lKey, lValue, result));
							rKey = $temp$rKey;
							rValue = $temp$rValue;
							_v0 = $temp$_v0;
							continue stepState;
						} else {
							if (_Utils_cmp(lKey, rKey) > 0) {
								return _Utils_Tuple2(
									list,
									A3(rightStep, rKey, rValue, result));
							} else {
								return _Utils_Tuple2(
									rest,
									A4(bothStep, lKey, lValue, rValue, result));
							}
						}
					}
				}
			});
		var _v3 = A3(
			$elm$core$Dict$foldl,
			stepState,
			_Utils_Tuple2(
				$elm$core$Dict$toList(leftDict),
				initialResult),
			rightDict);
		var leftovers = _v3.a;
		var intermediateResult = _v3.b;
		return A3(
			$elm$core$List$foldl,
			F2(
				function (_v4, result) {
					var k = _v4.a;
					var v = _v4.b;
					return A3(leftStep, k, v, result);
				}),
			intermediateResult,
			leftovers);
	});
var $elm$browser$Browser$Events$Event = F2(
	function (key, event) {
		return {event: event, key: key};
	});
var $elm$browser$Browser$Events$spawn = F3(
	function (router, key, _v0) {
		var node = _v0.a;
		var name = _v0.b;
		var actualNode = function () {
			if (node.$ === 'Document') {
				return _Browser_doc;
			} else {
				return _Browser_window;
			}
		}();
		return A2(
			$elm$core$Task$map,
			function (value) {
				return _Utils_Tuple2(key, value);
			},
			A3(
				_Browser_on,
				actualNode,
				name,
				function (event) {
					return A2(
						$elm$core$Platform$sendToSelf,
						router,
						A2($elm$browser$Browser$Events$Event, key, event));
				}));
	});
var $elm$core$Dict$union = F2(
	function (t1, t2) {
		return A3($elm$core$Dict$foldl, $elm$core$Dict$insert, t2, t1);
	});
var $elm$browser$Browser$Events$onEffects = F3(
	function (router, subs, state) {
		var stepRight = F3(
			function (key, sub, _v6) {
				var deads = _v6.a;
				var lives = _v6.b;
				var news = _v6.c;
				return _Utils_Tuple3(
					deads,
					lives,
					A2(
						$elm$core$List$cons,
						A3($elm$browser$Browser$Events$spawn, router, key, sub),
						news));
			});
		var stepLeft = F3(
			function (_v4, pid, _v5) {
				var deads = _v5.a;
				var lives = _v5.b;
				var news = _v5.c;
				return _Utils_Tuple3(
					A2($elm$core$List$cons, pid, deads),
					lives,
					news);
			});
		var stepBoth = F4(
			function (key, pid, _v2, _v3) {
				var deads = _v3.a;
				var lives = _v3.b;
				var news = _v3.c;
				return _Utils_Tuple3(
					deads,
					A3($elm$core$Dict$insert, key, pid, lives),
					news);
			});
		var newSubs = A2($elm$core$List$map, $elm$browser$Browser$Events$addKey, subs);
		var _v0 = A6(
			$elm$core$Dict$merge,
			stepLeft,
			stepBoth,
			stepRight,
			state.pids,
			$elm$core$Dict$fromList(newSubs),
			_Utils_Tuple3(_List_Nil, $elm$core$Dict$empty, _List_Nil));
		var deadPids = _v0.a;
		var livePids = _v0.b;
		var makeNewPids = _v0.c;
		return A2(
			$elm$core$Task$andThen,
			function (pids) {
				return $elm$core$Task$succeed(
					A2(
						$elm$browser$Browser$Events$State,
						newSubs,
						A2(
							$elm$core$Dict$union,
							livePids,
							$elm$core$Dict$fromList(pids))));
			},
			A2(
				$elm$core$Task$andThen,
				function (_v1) {
					return $elm$core$Task$sequence(makeNewPids);
				},
				$elm$core$Task$sequence(
					A2($elm$core$List$map, $elm$core$Process$kill, deadPids))));
	});
var $elm$browser$Browser$Events$onSelfMsg = F3(
	function (router, _v0, state) {
		var key = _v0.key;
		var event = _v0.event;
		var toMessage = function (_v2) {
			var subKey = _v2.a;
			var _v3 = _v2.b;
			var node = _v3.a;
			var name = _v3.b;
			var decoder = _v3.c;
			return _Utils_eq(subKey, key) ? A2(_Browser_decodeEvent, decoder, event) : $elm$core$Maybe$Nothing;
		};
		var messages = A2($elm$core$List$filterMap, toMessage, state.subs);
		return A2(
			$elm$core$Task$andThen,
			function (_v1) {
				return $elm$core$Task$succeed(state);
			},
			$elm$core$Task$sequence(
				A2(
					$elm$core$List$map,
					$elm$core$Platform$sendToApp(router),
					messages)));
	});
var $elm$browser$Browser$Events$subMap = F2(
	function (func, _v0) {
		var node = _v0.a;
		var name = _v0.b;
		var decoder = _v0.c;
		return A3(
			$elm$browser$Browser$Events$MySub,
			node,
			name,
			A2($elm$json$Json$Decode$map, func, decoder));
	});
_Platform_effectManagers['Browser.Events'] = _Platform_createManager($elm$browser$Browser$Events$init, $elm$browser$Browser$Events$onEffects, $elm$browser$Browser$Events$onSelfMsg, 0, $elm$browser$Browser$Events$subMap);
var $elm$browser$Browser$Events$subscription = _Platform_leaf('Browser.Events');
var $elm$browser$Browser$Events$on = F3(
	function (node, name, decoder) {
		return $elm$browser$Browser$Events$subscription(
			A3($elm$browser$Browser$Events$MySub, node, name, decoder));
	});
var $elm$browser$Browser$Events$onMouseMove = A2($elm$browser$Browser$Events$on, $elm$browser$Browser$Events$Document, 'mousemove');
var $elm$browser$Browser$Events$onMouseUp = A2($elm$browser$Browser$Events$on, $elm$browser$Browser$Events$Document, 'mouseup');
var $author$project$Main$Play$subscriptions = function (model) {
	var replaySubs = function () {
		var _v1 = model.replay;
		if (_v1.$ === 'Just') {
			var progress = _v1.a;
			return progress.paused ? _List_Nil : _List_fromArray(
				[
					$elm$browser$Browser$Events$onAnimationFrame($author$project$Main$Msg$ReplayFrame)
				]);
		} else {
			return _List_Nil;
		}
	}();
	var dragSubs = function () {
		var _v0 = model.drag;
		if (_v0.$ === 'Dragging') {
			return _List_fromArray(
				[
					$elm$browser$Browser$Events$onMouseMove($author$project$Main$Play$mouseMoveDecoder),
					$elm$browser$Browser$Events$onMouseUp($author$project$Main$Play$mouseUpDecoder)
				]);
		} else {
			return _List_Nil;
		}
	}();
	return $elm$core$Platform$Sub$batch(
		_Utils_ap(dragSubs, replaySubs));
};
var $author$project$Lab$subscriptions = function (model) {
	return $elm$core$Platform$Sub$batch(
		A2(
			$elm$core$List$filterMap,
			function (_v0) {
				var name = _v0.a;
				var panel = _v0.b;
				if (panel.$ === 'Playing') {
					var p = panel.a;
					return $elm$core$Maybe$Just(
						A2(
							$elm$core$Platform$Sub$map,
							$author$project$Lab$PlayMsg(name),
							$author$project$Main$Play$subscriptions(p)));
				} else {
					return $elm$core$Maybe$Nothing;
				}
			},
			$elm$core$Dict$toList(model.panels)));
};
var $author$project$Lab$CatalogFailed = function (a) {
	return {$: 'CatalogFailed', a: a};
};
var $author$project$Lab$CatalogLoaded = function (a) {
	return {$: 'CatalogLoaded', a: a};
};
var $author$project$Lab$NotSent = {$: 'NotSent'};
var $author$project$Lab$Playing = function (a) {
	return {$: 'Playing', a: a};
};
var $author$project$Main$Play$PuzzleSession = function (a) {
	return {$: 'PuzzleSession', a: a};
};
var $author$project$Lab$SendFailed = function (a) {
	return {$: 'SendFailed', a: a};
};
var $author$project$Lab$Sending = {$: 'Sending'};
var $author$project$Lab$Sent = {$: 'Sent'};
var $author$project$Lab$CatalogFetched = function (a) {
	return {$: 'CatalogFetched', a: a};
};
var $author$project$Lab$Catalog = F2(
	function (sessionId, puzzles) {
		return {puzzles: puzzles, sessionId: sessionId};
	});
var $elm$json$Json$Decode$int = _Json_decodeInt;
var $elm$json$Json$Decode$list = _Json_decodeList;
var $author$project$Lab$Puzzle = F3(
	function (name, title, initialState) {
		return {initialState: initialState, name: name, title: title};
	});
var $elm$json$Json$Decode$map3 = _Json_map3;
var $elm$json$Json$Decode$string = _Json_decodeString;
var $elm$json$Json$Decode$value = _Json_decodeValue;
var $author$project$Lab$puzzleDecoder = A4(
	$elm$json$Json$Decode$map3,
	$author$project$Lab$Puzzle,
	A2($elm$json$Json$Decode$field, 'name', $elm$json$Json$Decode$string),
	A2($elm$json$Json$Decode$field, 'title', $elm$json$Json$Decode$string),
	A2($elm$json$Json$Decode$field, 'initial_state', $elm$json$Json$Decode$value));
var $author$project$Lab$catalogDecoder = A3(
	$elm$json$Json$Decode$map2,
	$author$project$Lab$Catalog,
	A2($elm$json$Json$Decode$field, 'session_id', $elm$json$Json$Decode$int),
	A2(
		$elm$json$Json$Decode$field,
		'puzzles',
		$elm$json$Json$Decode$list($author$project$Lab$puzzleDecoder)));
var $elm$json$Json$Decode$decodeString = _Json_runOnString;
var $elm$http$Http$BadStatus_ = F2(
	function (a, b) {
		return {$: 'BadStatus_', a: a, b: b};
	});
var $elm$http$Http$BadUrl_ = function (a) {
	return {$: 'BadUrl_', a: a};
};
var $elm$http$Http$GoodStatus_ = F2(
	function (a, b) {
		return {$: 'GoodStatus_', a: a, b: b};
	});
var $elm$http$Http$NetworkError_ = {$: 'NetworkError_'};
var $elm$http$Http$Receiving = function (a) {
	return {$: 'Receiving', a: a};
};
var $elm$http$Http$Sending = function (a) {
	return {$: 'Sending', a: a};
};
var $elm$http$Http$Timeout_ = {$: 'Timeout_'};
var $elm$core$Maybe$isJust = function (maybe) {
	if (maybe.$ === 'Just') {
		return true;
	} else {
		return false;
	}
};
var $elm$core$Dict$get = F2(
	function (targetKey, dict) {
		get:
		while (true) {
			if (dict.$ === 'RBEmpty_elm_builtin') {
				return $elm$core$Maybe$Nothing;
			} else {
				var key = dict.b;
				var value = dict.c;
				var left = dict.d;
				var right = dict.e;
				var _v1 = A2($elm$core$Basics$compare, targetKey, key);
				switch (_v1.$) {
					case 'LT':
						var $temp$targetKey = targetKey,
							$temp$dict = left;
						targetKey = $temp$targetKey;
						dict = $temp$dict;
						continue get;
					case 'EQ':
						return $elm$core$Maybe$Just(value);
					default:
						var $temp$targetKey = targetKey,
							$temp$dict = right;
						targetKey = $temp$targetKey;
						dict = $temp$dict;
						continue get;
				}
			}
		}
	});
var $elm$core$Dict$getMin = function (dict) {
	getMin:
	while (true) {
		if ((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) {
			var left = dict.d;
			var $temp$dict = left;
			dict = $temp$dict;
			continue getMin;
		} else {
			return dict;
		}
	}
};
var $elm$core$Dict$moveRedLeft = function (dict) {
	if (((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) && (dict.e.$ === 'RBNode_elm_builtin')) {
		if ((dict.e.d.$ === 'RBNode_elm_builtin') && (dict.e.d.a.$ === 'Red')) {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v1 = dict.d;
			var lClr = _v1.a;
			var lK = _v1.b;
			var lV = _v1.c;
			var lLeft = _v1.d;
			var lRight = _v1.e;
			var _v2 = dict.e;
			var rClr = _v2.a;
			var rK = _v2.b;
			var rV = _v2.c;
			var rLeft = _v2.d;
			var _v3 = rLeft.a;
			var rlK = rLeft.b;
			var rlV = rLeft.c;
			var rlL = rLeft.d;
			var rlR = rLeft.e;
			var rRight = _v2.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				$elm$core$Dict$Red,
				rlK,
				rlV,
				A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					rlL),
				A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, rK, rV, rlR, rRight));
		} else {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v4 = dict.d;
			var lClr = _v4.a;
			var lK = _v4.b;
			var lV = _v4.c;
			var lLeft = _v4.d;
			var lRight = _v4.e;
			var _v5 = dict.e;
			var rClr = _v5.a;
			var rK = _v5.b;
			var rV = _v5.c;
			var rLeft = _v5.d;
			var rRight = _v5.e;
			if (clr.$ === 'Black') {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			}
		}
	} else {
		return dict;
	}
};
var $elm$core$Dict$moveRedRight = function (dict) {
	if (((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) && (dict.e.$ === 'RBNode_elm_builtin')) {
		if ((dict.d.d.$ === 'RBNode_elm_builtin') && (dict.d.d.a.$ === 'Red')) {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v1 = dict.d;
			var lClr = _v1.a;
			var lK = _v1.b;
			var lV = _v1.c;
			var _v2 = _v1.d;
			var _v3 = _v2.a;
			var llK = _v2.b;
			var llV = _v2.c;
			var llLeft = _v2.d;
			var llRight = _v2.e;
			var lRight = _v1.e;
			var _v4 = dict.e;
			var rClr = _v4.a;
			var rK = _v4.b;
			var rV = _v4.c;
			var rLeft = _v4.d;
			var rRight = _v4.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				$elm$core$Dict$Red,
				lK,
				lV,
				A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, llK, llV, llLeft, llRight),
				A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					lRight,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight)));
		} else {
			var clr = dict.a;
			var k = dict.b;
			var v = dict.c;
			var _v5 = dict.d;
			var lClr = _v5.a;
			var lK = _v5.b;
			var lV = _v5.c;
			var lLeft = _v5.d;
			var lRight = _v5.e;
			var _v6 = dict.e;
			var rClr = _v6.a;
			var rK = _v6.b;
			var rV = _v6.c;
			var rLeft = _v6.d;
			var rRight = _v6.e;
			if (clr.$ === 'Black') {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			} else {
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					$elm$core$Dict$Black,
					k,
					v,
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, lK, lV, lLeft, lRight),
					A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, rK, rV, rLeft, rRight));
			}
		}
	} else {
		return dict;
	}
};
var $elm$core$Dict$removeHelpPrepEQGT = F7(
	function (targetKey, dict, color, key, value, left, right) {
		if ((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Red')) {
			var _v1 = left.a;
			var lK = left.b;
			var lV = left.c;
			var lLeft = left.d;
			var lRight = left.e;
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				color,
				lK,
				lV,
				lLeft,
				A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Red, key, value, lRight, right));
		} else {
			_v2$2:
			while (true) {
				if ((right.$ === 'RBNode_elm_builtin') && (right.a.$ === 'Black')) {
					if (right.d.$ === 'RBNode_elm_builtin') {
						if (right.d.a.$ === 'Black') {
							var _v3 = right.a;
							var _v4 = right.d;
							var _v5 = _v4.a;
							return $elm$core$Dict$moveRedRight(dict);
						} else {
							break _v2$2;
						}
					} else {
						var _v6 = right.a;
						var _v7 = right.d;
						return $elm$core$Dict$moveRedRight(dict);
					}
				} else {
					break _v2$2;
				}
			}
			return dict;
		}
	});
var $elm$core$Dict$removeMin = function (dict) {
	if ((dict.$ === 'RBNode_elm_builtin') && (dict.d.$ === 'RBNode_elm_builtin')) {
		var color = dict.a;
		var key = dict.b;
		var value = dict.c;
		var left = dict.d;
		var lColor = left.a;
		var lLeft = left.d;
		var right = dict.e;
		if (lColor.$ === 'Black') {
			if ((lLeft.$ === 'RBNode_elm_builtin') && (lLeft.a.$ === 'Red')) {
				var _v3 = lLeft.a;
				return A5(
					$elm$core$Dict$RBNode_elm_builtin,
					color,
					key,
					value,
					$elm$core$Dict$removeMin(left),
					right);
			} else {
				var _v4 = $elm$core$Dict$moveRedLeft(dict);
				if (_v4.$ === 'RBNode_elm_builtin') {
					var nColor = _v4.a;
					var nKey = _v4.b;
					var nValue = _v4.c;
					var nLeft = _v4.d;
					var nRight = _v4.e;
					return A5(
						$elm$core$Dict$balance,
						nColor,
						nKey,
						nValue,
						$elm$core$Dict$removeMin(nLeft),
						nRight);
				} else {
					return $elm$core$Dict$RBEmpty_elm_builtin;
				}
			}
		} else {
			return A5(
				$elm$core$Dict$RBNode_elm_builtin,
				color,
				key,
				value,
				$elm$core$Dict$removeMin(left),
				right);
		}
	} else {
		return $elm$core$Dict$RBEmpty_elm_builtin;
	}
};
var $elm$core$Dict$removeHelp = F2(
	function (targetKey, dict) {
		if (dict.$ === 'RBEmpty_elm_builtin') {
			return $elm$core$Dict$RBEmpty_elm_builtin;
		} else {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			if (_Utils_cmp(targetKey, key) < 0) {
				if ((left.$ === 'RBNode_elm_builtin') && (left.a.$ === 'Black')) {
					var _v4 = left.a;
					var lLeft = left.d;
					if ((lLeft.$ === 'RBNode_elm_builtin') && (lLeft.a.$ === 'Red')) {
						var _v6 = lLeft.a;
						return A5(
							$elm$core$Dict$RBNode_elm_builtin,
							color,
							key,
							value,
							A2($elm$core$Dict$removeHelp, targetKey, left),
							right);
					} else {
						var _v7 = $elm$core$Dict$moveRedLeft(dict);
						if (_v7.$ === 'RBNode_elm_builtin') {
							var nColor = _v7.a;
							var nKey = _v7.b;
							var nValue = _v7.c;
							var nLeft = _v7.d;
							var nRight = _v7.e;
							return A5(
								$elm$core$Dict$balance,
								nColor,
								nKey,
								nValue,
								A2($elm$core$Dict$removeHelp, targetKey, nLeft),
								nRight);
						} else {
							return $elm$core$Dict$RBEmpty_elm_builtin;
						}
					}
				} else {
					return A5(
						$elm$core$Dict$RBNode_elm_builtin,
						color,
						key,
						value,
						A2($elm$core$Dict$removeHelp, targetKey, left),
						right);
				}
			} else {
				return A2(
					$elm$core$Dict$removeHelpEQGT,
					targetKey,
					A7($elm$core$Dict$removeHelpPrepEQGT, targetKey, dict, color, key, value, left, right));
			}
		}
	});
var $elm$core$Dict$removeHelpEQGT = F2(
	function (targetKey, dict) {
		if (dict.$ === 'RBNode_elm_builtin') {
			var color = dict.a;
			var key = dict.b;
			var value = dict.c;
			var left = dict.d;
			var right = dict.e;
			if (_Utils_eq(targetKey, key)) {
				var _v1 = $elm$core$Dict$getMin(right);
				if (_v1.$ === 'RBNode_elm_builtin') {
					var minKey = _v1.b;
					var minValue = _v1.c;
					return A5(
						$elm$core$Dict$balance,
						color,
						minKey,
						minValue,
						left,
						$elm$core$Dict$removeMin(right));
				} else {
					return $elm$core$Dict$RBEmpty_elm_builtin;
				}
			} else {
				return A5(
					$elm$core$Dict$balance,
					color,
					key,
					value,
					left,
					A2($elm$core$Dict$removeHelp, targetKey, right));
			}
		} else {
			return $elm$core$Dict$RBEmpty_elm_builtin;
		}
	});
var $elm$core$Dict$remove = F2(
	function (key, dict) {
		var _v0 = A2($elm$core$Dict$removeHelp, key, dict);
		if ((_v0.$ === 'RBNode_elm_builtin') && (_v0.a.$ === 'Red')) {
			var _v1 = _v0.a;
			var k = _v0.b;
			var v = _v0.c;
			var l = _v0.d;
			var r = _v0.e;
			return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, k, v, l, r);
		} else {
			var x = _v0;
			return x;
		}
	});
var $elm$core$Dict$update = F3(
	function (targetKey, alter, dictionary) {
		var _v0 = alter(
			A2($elm$core$Dict$get, targetKey, dictionary));
		if (_v0.$ === 'Just') {
			var value = _v0.a;
			return A3($elm$core$Dict$insert, targetKey, value, dictionary);
		} else {
			return A2($elm$core$Dict$remove, targetKey, dictionary);
		}
	});
var $elm$core$Basics$composeR = F3(
	function (f, g, x) {
		return g(
			f(x));
	});
var $elm$http$Http$expectStringResponse = F2(
	function (toMsg, toResult) {
		return A3(
			_Http_expect,
			'',
			$elm$core$Basics$identity,
			A2($elm$core$Basics$composeR, toResult, toMsg));
	});
var $elm$core$Result$mapError = F2(
	function (f, result) {
		if (result.$ === 'Ok') {
			var v = result.a;
			return $elm$core$Result$Ok(v);
		} else {
			var e = result.a;
			return $elm$core$Result$Err(
				f(e));
		}
	});
var $elm$http$Http$BadBody = function (a) {
	return {$: 'BadBody', a: a};
};
var $elm$http$Http$BadStatus = function (a) {
	return {$: 'BadStatus', a: a};
};
var $elm$http$Http$BadUrl = function (a) {
	return {$: 'BadUrl', a: a};
};
var $elm$http$Http$NetworkError = {$: 'NetworkError'};
var $elm$http$Http$Timeout = {$: 'Timeout'};
var $elm$http$Http$resolve = F2(
	function (toResult, response) {
		switch (response.$) {
			case 'BadUrl_':
				var url = response.a;
				return $elm$core$Result$Err(
					$elm$http$Http$BadUrl(url));
			case 'Timeout_':
				return $elm$core$Result$Err($elm$http$Http$Timeout);
			case 'NetworkError_':
				return $elm$core$Result$Err($elm$http$Http$NetworkError);
			case 'BadStatus_':
				var metadata = response.a;
				return $elm$core$Result$Err(
					$elm$http$Http$BadStatus(metadata.statusCode));
			default:
				var body = response.b;
				return A2(
					$elm$core$Result$mapError,
					$elm$http$Http$BadBody,
					toResult(body));
		}
	});
var $elm$http$Http$expectJson = F2(
	function (toMsg, decoder) {
		return A2(
			$elm$http$Http$expectStringResponse,
			toMsg,
			$elm$http$Http$resolve(
				function (string) {
					return A2(
						$elm$core$Result$mapError,
						$elm$json$Json$Decode$errorToString,
						A2($elm$json$Json$Decode$decodeString, decoder, string));
				}));
	});
var $elm$http$Http$emptyBody = _Http_emptyBody;
var $elm$http$Http$Request = function (a) {
	return {$: 'Request', a: a};
};
var $elm$http$Http$State = F2(
	function (reqs, subs) {
		return {reqs: reqs, subs: subs};
	});
var $elm$http$Http$init = $elm$core$Task$succeed(
	A2($elm$http$Http$State, $elm$core$Dict$empty, _List_Nil));
var $elm$http$Http$updateReqs = F3(
	function (router, cmds, reqs) {
		updateReqs:
		while (true) {
			if (!cmds.b) {
				return $elm$core$Task$succeed(reqs);
			} else {
				var cmd = cmds.a;
				var otherCmds = cmds.b;
				if (cmd.$ === 'Cancel') {
					var tracker = cmd.a;
					var _v2 = A2($elm$core$Dict$get, tracker, reqs);
					if (_v2.$ === 'Nothing') {
						var $temp$router = router,
							$temp$cmds = otherCmds,
							$temp$reqs = reqs;
						router = $temp$router;
						cmds = $temp$cmds;
						reqs = $temp$reqs;
						continue updateReqs;
					} else {
						var pid = _v2.a;
						return A2(
							$elm$core$Task$andThen,
							function (_v3) {
								return A3(
									$elm$http$Http$updateReqs,
									router,
									otherCmds,
									A2($elm$core$Dict$remove, tracker, reqs));
							},
							$elm$core$Process$kill(pid));
					}
				} else {
					var req = cmd.a;
					return A2(
						$elm$core$Task$andThen,
						function (pid) {
							var _v4 = req.tracker;
							if (_v4.$ === 'Nothing') {
								return A3($elm$http$Http$updateReqs, router, otherCmds, reqs);
							} else {
								var tracker = _v4.a;
								return A3(
									$elm$http$Http$updateReqs,
									router,
									otherCmds,
									A3($elm$core$Dict$insert, tracker, pid, reqs));
							}
						},
						$elm$core$Process$spawn(
							A3(
								_Http_toTask,
								router,
								$elm$core$Platform$sendToApp(router),
								req)));
				}
			}
		}
	});
var $elm$http$Http$onEffects = F4(
	function (router, cmds, subs, state) {
		return A2(
			$elm$core$Task$andThen,
			function (reqs) {
				return $elm$core$Task$succeed(
					A2($elm$http$Http$State, reqs, subs));
			},
			A3($elm$http$Http$updateReqs, router, cmds, state.reqs));
	});
var $elm$http$Http$maybeSend = F4(
	function (router, desiredTracker, progress, _v0) {
		var actualTracker = _v0.a;
		var toMsg = _v0.b;
		return _Utils_eq(desiredTracker, actualTracker) ? $elm$core$Maybe$Just(
			A2(
				$elm$core$Platform$sendToApp,
				router,
				toMsg(progress))) : $elm$core$Maybe$Nothing;
	});
var $elm$http$Http$onSelfMsg = F3(
	function (router, _v0, state) {
		var tracker = _v0.a;
		var progress = _v0.b;
		return A2(
			$elm$core$Task$andThen,
			function (_v1) {
				return $elm$core$Task$succeed(state);
			},
			$elm$core$Task$sequence(
				A2(
					$elm$core$List$filterMap,
					A3($elm$http$Http$maybeSend, router, tracker, progress),
					state.subs)));
	});
var $elm$http$Http$Cancel = function (a) {
	return {$: 'Cancel', a: a};
};
var $elm$http$Http$cmdMap = F2(
	function (func, cmd) {
		if (cmd.$ === 'Cancel') {
			var tracker = cmd.a;
			return $elm$http$Http$Cancel(tracker);
		} else {
			var r = cmd.a;
			return $elm$http$Http$Request(
				{
					allowCookiesFromOtherDomains: r.allowCookiesFromOtherDomains,
					body: r.body,
					expect: A2(_Http_mapExpect, func, r.expect),
					headers: r.headers,
					method: r.method,
					timeout: r.timeout,
					tracker: r.tracker,
					url: r.url
				});
		}
	});
var $elm$http$Http$MySub = F2(
	function (a, b) {
		return {$: 'MySub', a: a, b: b};
	});
var $elm$http$Http$subMap = F2(
	function (func, _v0) {
		var tracker = _v0.a;
		var toMsg = _v0.b;
		return A2(
			$elm$http$Http$MySub,
			tracker,
			A2($elm$core$Basics$composeR, toMsg, func));
	});
_Platform_effectManagers['Http'] = _Platform_createManager($elm$http$Http$init, $elm$http$Http$onEffects, $elm$http$Http$onSelfMsg, $elm$http$Http$cmdMap, $elm$http$Http$subMap);
var $elm$http$Http$command = _Platform_leaf('Http');
var $elm$http$Http$subscription = _Platform_leaf('Http');
var $elm$http$Http$request = function (r) {
	return $elm$http$Http$command(
		$elm$http$Http$Request(
			{allowCookiesFromOtherDomains: false, body: r.body, expect: r.expect, headers: r.headers, method: r.method, timeout: r.timeout, tracker: r.tracker, url: r.url}));
};
var $elm$http$Http$get = function (r) {
	return $elm$http$Http$request(
		{body: $elm$http$Http$emptyBody, expect: r.expect, headers: _List_Nil, method: 'GET', timeout: $elm$core$Maybe$Nothing, tracker: $elm$core$Maybe$Nothing, url: r.url});
};
var $author$project$Lab$fetchCatalog = $elm$http$Http$get(
	{
		expect: A2($elm$http$Http$expectJson, $author$project$Lab$CatalogFetched, $author$project$Lab$catalogDecoder),
		url: '/gopher/board-lab/puzzles'
	});
var $author$project$Lab$emptyAnnotation = {status: $author$project$Lab$NotSent, text: ''};
var $elm$core$Maybe$withDefault = F2(
	function (_default, maybe) {
		if (maybe.$ === 'Just') {
			var value = maybe.a;
			return value;
		} else {
			return _default;
		}
	});
var $author$project$Lab$getAnnotation = F2(
	function (puzzleName, model) {
		return A2(
			$elm$core$Maybe$withDefault,
			$author$project$Lab$emptyAnnotation,
			A2($elm$core$Dict$get, puzzleName, model.annotations));
	});
var $author$project$Lab$httpErrorToString = function (err) {
	switch (err.$) {
		case 'BadUrl':
			var s = err.a;
			return 'bad URL: ' + s;
		case 'Timeout':
			return 'timeout';
		case 'NetworkError':
			return 'network error';
		case 'BadStatus':
			var code = err.a;
			return 'bad status: ' + $elm$core$String$fromInt(code);
		default:
			var s = err.a;
			return 'bad body: ' + s;
	}
};
var $author$project$Main$State$Inform = {$: 'Inform'};
var $author$project$Main$State$Scold = {$: 'Scold'};
var $author$project$Main$State$NotAnimating = {$: 'NotAnimating'};
var $author$project$Main$State$NotDragging = {$: 'NotDragging'};
var $author$project$Game$Hand$empty = {handCards: _List_Nil};
var $author$project$Game$CardStack$size = function (s) {
	return $elm$core$List$length(s.boardCards);
};
var $author$project$Game$StackType$Bogus = {$: 'Bogus'};
var $author$project$Game$StackType$Dup = {$: 'Dup'};
var $author$project$Game$StackType$Incomplete = {$: 'Incomplete'};
var $author$project$Game$StackType$Set = {$: 'Set'};
var $author$project$Game$StackType$PureRun = {$: 'PureRun'};
var $author$project$Game$StackType$RedBlackRun = {$: 'RedBlackRun'};
var $author$project$Game$Card$Black = {$: 'Black'};
var $author$project$Game$Card$Red = {$: 'Red'};
var $author$project$Game$Card$suitColor = function (suit) {
	switch (suit.$) {
		case 'Club':
			return $author$project$Game$Card$Black;
		case 'Spade':
			return $author$project$Game$Card$Black;
		case 'Diamond':
			return $author$project$Game$Card$Red;
		default:
			return $author$project$Game$Card$Red;
	}
};
var $author$project$Game$Card$cardColor = function (card) {
	return $author$project$Game$Card$suitColor(card.suit);
};
var $author$project$Game$Card$isPairOfDups = F2(
	function (a, b) {
		return _Utils_eq(a.value, b.value) && _Utils_eq(a.suit, b.suit);
	});
var $elm$core$Basics$neq = _Utils_notEqual;
var $author$project$Game$Card$Ace = {$: 'Ace'};
var $author$project$Game$Card$Eight = {$: 'Eight'};
var $author$project$Game$Card$Five = {$: 'Five'};
var $author$project$Game$Card$Four = {$: 'Four'};
var $author$project$Game$Card$Jack = {$: 'Jack'};
var $author$project$Game$Card$King = {$: 'King'};
var $author$project$Game$Card$Nine = {$: 'Nine'};
var $author$project$Game$Card$Queen = {$: 'Queen'};
var $author$project$Game$Card$Seven = {$: 'Seven'};
var $author$project$Game$Card$Six = {$: 'Six'};
var $author$project$Game$Card$Ten = {$: 'Ten'};
var $author$project$Game$Card$Three = {$: 'Three'};
var $author$project$Game$Card$Two = {$: 'Two'};
var $author$project$Game$StackType$successor = function (v) {
	switch (v.$) {
		case 'Ace':
			return $author$project$Game$Card$Two;
		case 'Two':
			return $author$project$Game$Card$Three;
		case 'Three':
			return $author$project$Game$Card$Four;
		case 'Four':
			return $author$project$Game$Card$Five;
		case 'Five':
			return $author$project$Game$Card$Six;
		case 'Six':
			return $author$project$Game$Card$Seven;
		case 'Seven':
			return $author$project$Game$Card$Eight;
		case 'Eight':
			return $author$project$Game$Card$Nine;
		case 'Nine':
			return $author$project$Game$Card$Ten;
		case 'Ten':
			return $author$project$Game$Card$Jack;
		case 'Jack':
			return $author$project$Game$Card$Queen;
		case 'Queen':
			return $author$project$Game$Card$King;
		default:
			return $author$project$Game$Card$Ace;
	}
};
var $author$project$Game$StackType$cardPairStackType = F2(
	function (a, b) {
		return A2($author$project$Game$Card$isPairOfDups, a, b) ? $author$project$Game$StackType$Dup : (_Utils_eq(a.value, b.value) ? $author$project$Game$StackType$Set : (_Utils_eq(
			b.value,
			$author$project$Game$StackType$successor(a.value)) ? (_Utils_eq(a.suit, b.suit) ? $author$project$Game$StackType$PureRun : ((!_Utils_eq(
			$author$project$Game$Card$cardColor(a),
			$author$project$Game$Card$cardColor(b))) ? $author$project$Game$StackType$RedBlackRun : $author$project$Game$StackType$Bogus)) : $author$project$Game$StackType$Bogus));
	});
var $author$project$Game$StackType$followsConsistentPattern = F2(
	function (stackType, cards) {
		if (cards.b && cards.b.b) {
			var a = cards.a;
			var _v1 = cards.b;
			var b = _v1.a;
			var rest = _v1.b;
			return _Utils_eq(
				A2($author$project$Game$StackType$cardPairStackType, a, b),
				stackType) && A2(
				$author$project$Game$StackType$followsConsistentPattern,
				stackType,
				A2($elm$core$List$cons, b, rest));
		} else {
			return true;
		}
	});
var $elm$core$List$any = F2(
	function (isOkay, list) {
		any:
		while (true) {
			if (!list.b) {
				return false;
			} else {
				var x = list.a;
				var xs = list.b;
				if (isOkay(x)) {
					return true;
				} else {
					var $temp$isOkay = isOkay,
						$temp$list = xs;
					isOkay = $temp$isOkay;
					list = $temp$list;
					continue any;
				}
			}
		}
	});
var $author$project$Game$StackType$hasDuplicateCards = function (cards) {
	if (!cards.b) {
		return false;
	} else {
		var first = cards.a;
		var rest = cards.b;
		return A2(
			$elm$core$List$any,
			$author$project$Game$Card$isPairOfDups(first),
			rest) || $author$project$Game$StackType$hasDuplicateCards(rest);
	}
};
var $elm$core$Basics$not = _Basics_not;
var $author$project$Game$StackType$getStackType = function (cards) {
	if (!cards.b) {
		return $author$project$Game$StackType$Incomplete;
	} else {
		if (!cards.b.b) {
			return $author$project$Game$StackType$Incomplete;
		} else {
			var a = cards.a;
			var _v1 = cards.b;
			var b = _v1.a;
			var provisional = A2($author$project$Game$StackType$cardPairStackType, a, b);
			switch (provisional.$) {
				case 'Bogus':
					return $author$project$Game$StackType$Bogus;
				case 'Dup':
					return $author$project$Game$StackType$Dup;
				default:
					return ($elm$core$List$length(cards) === 2) ? $author$project$Game$StackType$Incomplete : ((_Utils_eq(provisional, $author$project$Game$StackType$Set) && $author$project$Game$StackType$hasDuplicateCards(cards)) ? $author$project$Game$StackType$Dup : ((!A2($author$project$Game$StackType$followsConsistentPattern, provisional, cards)) ? $author$project$Game$StackType$Bogus : provisional));
			}
		}
	}
};
var $author$project$Game$CardStack$stackCards = function (s) {
	return A2(
		$elm$core$List$map,
		function ($) {
			return $.card;
		},
		s.boardCards);
};
var $author$project$Game$CardStack$stackType = function (s) {
	return $author$project$Game$StackType$getStackType(
		$author$project$Game$CardStack$stackCards(s));
};
var $author$project$Game$Score$stackTypeValue = function (stackType) {
	switch (stackType.$) {
		case 'PureRun':
			return 100;
		case 'Set':
			return 60;
		case 'RedBlackRun':
			return 50;
		case 'Incomplete':
			return 0;
		case 'Bogus':
			return 0;
		default:
			return 0;
	}
};
var $author$project$Game$Score$forStack = function (stack) {
	return $author$project$Game$CardStack$size(stack) * $author$project$Game$Score$stackTypeValue(
		$author$project$Game$CardStack$stackType(stack));
};
var $elm$core$List$sum = function (numbers) {
	return A3($elm$core$List$foldl, $elm$core$Basics$add, 0, numbers);
};
var $author$project$Game$Score$forStacks = function (stacks) {
	return $elm$core$List$sum(
		A2($elm$core$List$map, $author$project$Game$Score$forStack, stacks));
};
var $author$project$Game$Dealer$openingShorthands = _List_fromArray(
	['KS,AS,2S,3S', 'TD,JD,QD,KD', '2H,3H,4H', '7S,7D,7C', 'AC,AD,AH', '2C,3D,4C,5H,6S,7H']);
var $author$project$Game$Card$DeckOne = {$: 'DeckOne'};
var $author$project$Game$CardStack$FirmlyOnBoard = {$: 'FirmlyOnBoard'};
var $elm$core$String$cons = _String_cons;
var $elm$core$String$fromChar = function (_char) {
	return A2($elm$core$String$cons, _char, '');
};
var $elm$core$Maybe$map2 = F3(
	function (func, ma, mb) {
		if (ma.$ === 'Nothing') {
			return $elm$core$Maybe$Nothing;
		} else {
			var a = ma.a;
			if (mb.$ === 'Nothing') {
				return $elm$core$Maybe$Nothing;
			} else {
				var b = mb.a;
				return $elm$core$Maybe$Just(
					A2(func, a, b));
			}
		}
	});
var $author$project$Game$Card$Club = {$: 'Club'};
var $author$project$Game$Card$Diamond = {$: 'Diamond'};
var $author$project$Game$Card$Heart = {$: 'Heart'};
var $author$project$Game$Card$Spade = {$: 'Spade'};
var $author$project$Game$Card$suitFromLabel = function (label) {
	switch (label) {
		case 'C':
			return $elm$core$Maybe$Just($author$project$Game$Card$Club);
		case 'D':
			return $elm$core$Maybe$Just($author$project$Game$Card$Diamond);
		case 'H':
			return $elm$core$Maybe$Just($author$project$Game$Card$Heart);
		case 'S':
			return $elm$core$Maybe$Just($author$project$Game$Card$Spade);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $elm$core$String$foldr = _String_foldr;
var $elm$core$String$toList = function (string) {
	return A3($elm$core$String$foldr, $elm$core$List$cons, _List_Nil, string);
};
var $author$project$Game$Card$valueFromLabel = function (label) {
	switch (label) {
		case 'A':
			return $elm$core$Maybe$Just($author$project$Game$Card$Ace);
		case '2':
			return $elm$core$Maybe$Just($author$project$Game$Card$Two);
		case '3':
			return $elm$core$Maybe$Just($author$project$Game$Card$Three);
		case '4':
			return $elm$core$Maybe$Just($author$project$Game$Card$Four);
		case '5':
			return $elm$core$Maybe$Just($author$project$Game$Card$Five);
		case '6':
			return $elm$core$Maybe$Just($author$project$Game$Card$Six);
		case '7':
			return $elm$core$Maybe$Just($author$project$Game$Card$Seven);
		case '8':
			return $elm$core$Maybe$Just($author$project$Game$Card$Eight);
		case '9':
			return $elm$core$Maybe$Just($author$project$Game$Card$Nine);
		case 'T':
			return $elm$core$Maybe$Just($author$project$Game$Card$Ten);
		case 'J':
			return $elm$core$Maybe$Just($author$project$Game$Card$Jack);
		case 'Q':
			return $elm$core$Maybe$Just($author$project$Game$Card$Queen);
		case 'K':
			return $elm$core$Maybe$Just($author$project$Game$Card$King);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$Card$cardFromLabel = F2(
	function (label, deck) {
		var _v0 = $elm$core$String$toList(label);
		if ((_v0.b && _v0.b.b) && (!_v0.b.b.b)) {
			var v = _v0.a;
			var _v1 = _v0.b;
			var s = _v1.a;
			return A3(
				$elm$core$Maybe$map2,
				F2(
					function (value, suit) {
						return {originDeck: deck, suit: suit, value: value};
					}),
				$author$project$Game$Card$valueFromLabel(
					$elm$core$String$fromChar(v)),
				$author$project$Game$Card$suitFromLabel(
					$elm$core$String$fromChar(s)));
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $elm$core$Maybe$map = F2(
	function (f, maybe) {
		if (maybe.$ === 'Just') {
			var value = maybe.a;
			return $elm$core$Maybe$Just(
				f(value));
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$CardStack$fromShorthand = F3(
	function (shorthand, deck, loc) {
		return A2(
			$elm$core$Maybe$map,
			function (cards) {
				return {
					boardCards: A2(
						$elm$core$List$map,
						function (c) {
							return {card: c, state: $author$project$Game$CardStack$FirmlyOnBoard};
						},
						cards),
					loc: loc
				};
			},
			A3(
				$elm$core$List$foldr,
				$elm$core$Maybe$map2($elm$core$List$cons),
				$elm$core$Maybe$Just(_List_Nil),
				A2(
					$elm$core$List$map,
					function (label) {
						return A2($author$project$Game$Card$cardFromLabel, label, deck);
					},
					A2($elm$core$String$split, ',', shorthand))));
	});
var $elm$core$Basics$modBy = _Basics_modBy;
var $author$project$Game$Dealer$rowLoc = function (row) {
	var col = A2($elm$core$Basics$modBy, 5, (row * 3) + 1);
	return {left: 40 + (col * 30), top: 20 + (row * 60)};
};
var $author$project$Game$Dealer$stackFromRow = F2(
	function (row, sig) {
		return A3(
			$author$project$Game$CardStack$fromShorthand,
			sig,
			$author$project$Game$Card$DeckOne,
			$author$project$Game$Dealer$rowLoc(row));
	});
var $author$project$Game$Dealer$initialBoard = A2(
	$elm$core$List$filterMap,
	$elm$core$Basics$identity,
	A2($elm$core$List$indexedMap, $author$project$Game$Dealer$stackFromRow, $author$project$Game$Dealer$openingShorthands));
var $author$project$Game$Card$DeckTwo = {$: 'DeckTwo'};
var $author$project$Game$CardStack$HandNormal = {$: 'HandNormal'};
var $author$project$Game$Hand$addCards = F3(
	function (cards, state, h) {
		var newHandCards = A2(
			$elm$core$List$map,
			function (c) {
				return {card: c, state: state};
			},
			cards);
		return _Utils_update(
			h,
			{
				handCards: _Utils_ap(h.handCards, newHandCards)
			});
	});
var $author$project$Game$Dealer$openingHandLabels = _List_fromArray(
	['7H', '8C', '4S', '9D', 'QS', 'KH', 'JH', '6H', 'TS', '5D', '8H', '3C', '2D', '9C', '6C']);
var $author$project$Game$Dealer$openingHand = function () {
	var cards = A2(
		$elm$core$List$filterMap,
		function (label) {
			return A2($author$project$Game$Card$cardFromLabel, label, $author$project$Game$Card$DeckTwo);
		},
		$author$project$Game$Dealer$openingHandLabels);
	return A3($author$project$Game$Hand$addCards, cards, $author$project$Game$CardStack$HandNormal, $author$project$Game$Hand$empty);
}();
var $author$project$Main$State$baseModel = {
	actionLog: _List_Nil,
	activePlayerIndex: 0,
	agentProgram: $elm$core$Maybe$Nothing,
	board: $author$project$Game$Dealer$initialBoard,
	cardsPlayedThisTurn: 0,
	deck: _List_Nil,
	drag: $author$project$Main$State$NotDragging,
	gameId: 'default',
	hands: _List_fromArray(
		[$author$project$Game$Dealer$openingHand, $author$project$Game$Hand$empty]),
	hideTurnControls: false,
	hintedCards: _List_Nil,
	popup: $elm$core$Maybe$Nothing,
	puzzleName: $elm$core$Maybe$Nothing,
	replay: $elm$core$Maybe$Nothing,
	replayAnim: $author$project$Main$State$NotAnimating,
	replayBaseline: $elm$core$Maybe$Nothing,
	replayBoardRect: $elm$core$Maybe$Nothing,
	score: $author$project$Game$Score$forStacks($author$project$Game$Dealer$initialBoard),
	scores: _List_fromArray(
		[0, 0]),
	sessionId: $elm$core$Maybe$Nothing,
	status: {kind: $author$project$Main$State$Inform, text: 'You may begin moving.'},
	turnIndex: 0,
	turnStartBoardScore: $author$project$Game$Score$forStacks($author$project$Game$Dealer$initialBoard),
	victorAwarded: false
};
var $author$project$Main$Play$modelAtInitial = F2(
	function (initial, model) {
		return _Utils_update(
			model,
			{
				activePlayerIndex: initial.activePlayerIndex,
				board: initial.board,
				cardsPlayedThisTurn: initial.cardsPlayedThisTurn,
				deck: initial.deck,
				hands: initial.hands,
				replayBaseline: $elm$core$Maybe$Just(initial),
				score: $author$project$Game$Score$forStacks(initial.board),
				scores: initial.scores,
				turnIndex: initial.turnIndex,
				turnStartBoardScore: initial.turnStartBoardScore,
				victorAwarded: initial.victorAwarded
			});
	});
var $author$project$Main$Play$bootstrapPuzzle = F3(
	function (initial, puzzleName, model) {
		return A2(
			$author$project$Main$Play$modelAtInitial,
			initial,
			_Utils_update(
				model,
				{
					actionLog: _List_Nil,
					status: {kind: $author$project$Main$State$Inform, text: 'Puzzle ' + (puzzleName + ' loaded.')}
				}));
	});
var $elm$json$Json$Decode$decodeValue = _Json_run;
var $author$project$Main$Msg$ActionLogFetched = function (a) {
	return {$: 'ActionLogFetched', a: a};
};
var $author$project$Main$State$ActionLogBundle = F2(
	function (initialState, actions) {
		return {actions: actions, initialState: initialState};
	});
var $author$project$Main$State$ActionLogEntry = F3(
	function (action, gesturePath, pathFrame) {
		return {action: action, gesturePath: gesturePath, pathFrame: pathFrame};
	});
var $author$project$Main$State$ViewportFrame = {$: 'ViewportFrame'};
var $elm$json$Json$Decode$at = F2(
	function (fields, decoder) {
		return A3($elm$core$List$foldr, $elm$json$Json$Decode$field, decoder, fields);
	});
var $elm$json$Json$Decode$andThen = _Json_andThen;
var $author$project$Game$WireAction$CompleteTurn = {$: 'CompleteTurn'};
var $author$project$Game$WireAction$MergeHand = function (a) {
	return {$: 'MergeHand', a: a};
};
var $author$project$Game$WireAction$MergeStack = function (a) {
	return {$: 'MergeStack', a: a};
};
var $author$project$Game$WireAction$MoveStack = function (a) {
	return {$: 'MoveStack', a: a};
};
var $author$project$Game$WireAction$PlaceHand = function (a) {
	return {$: 'PlaceHand', a: a};
};
var $author$project$Game$WireAction$Split = function (a) {
	return {$: 'Split', a: a};
};
var $author$project$Game$WireAction$Undo = {$: 'Undo'};
var $author$project$Game$CardStack$boardLocationDecoder = A3(
	$elm$json$Json$Decode$map2,
	F2(
		function (top, left) {
			return {left: left, top: top};
		}),
	A2($elm$json$Json$Decode$field, 'top', $elm$json$Json$Decode$int),
	A2($elm$json$Json$Decode$field, 'left', $elm$json$Json$Decode$int));
var $elm$json$Json$Decode$fail = _Json_fail;
var $author$project$Game$Card$intDecoderVia = F2(
	function (toMaybe, label) {
		return A2(
			$elm$json$Json$Decode$andThen,
			function (n) {
				var _v0 = toMaybe(n);
				if (_v0.$ === 'Just') {
					var a = _v0.a;
					return $elm$json$Json$Decode$succeed(a);
				} else {
					return $elm$json$Json$Decode$fail(
						'invalid ' + (label + (': ' + $elm$core$String$fromInt(n))));
				}
			},
			$elm$json$Json$Decode$int);
	});
var $author$project$Game$Card$intToCardValue = function (n) {
	switch (n) {
		case 1:
			return $elm$core$Maybe$Just($author$project$Game$Card$Ace);
		case 2:
			return $elm$core$Maybe$Just($author$project$Game$Card$Two);
		case 3:
			return $elm$core$Maybe$Just($author$project$Game$Card$Three);
		case 4:
			return $elm$core$Maybe$Just($author$project$Game$Card$Four);
		case 5:
			return $elm$core$Maybe$Just($author$project$Game$Card$Five);
		case 6:
			return $elm$core$Maybe$Just($author$project$Game$Card$Six);
		case 7:
			return $elm$core$Maybe$Just($author$project$Game$Card$Seven);
		case 8:
			return $elm$core$Maybe$Just($author$project$Game$Card$Eight);
		case 9:
			return $elm$core$Maybe$Just($author$project$Game$Card$Nine);
		case 10:
			return $elm$core$Maybe$Just($author$project$Game$Card$Ten);
		case 11:
			return $elm$core$Maybe$Just($author$project$Game$Card$Jack);
		case 12:
			return $elm$core$Maybe$Just($author$project$Game$Card$Queen);
		case 13:
			return $elm$core$Maybe$Just($author$project$Game$Card$King);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$Card$intToOriginDeck = function (n) {
	switch (n) {
		case 0:
			return $elm$core$Maybe$Just($author$project$Game$Card$DeckOne);
		case 1:
			return $elm$core$Maybe$Just($author$project$Game$Card$DeckTwo);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$Card$intToSuit = function (n) {
	switch (n) {
		case 0:
			return $elm$core$Maybe$Just($author$project$Game$Card$Club);
		case 1:
			return $elm$core$Maybe$Just($author$project$Game$Card$Diamond);
		case 2:
			return $elm$core$Maybe$Just($author$project$Game$Card$Spade);
		case 3:
			return $elm$core$Maybe$Just($author$project$Game$Card$Heart);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$Card$cardDecoder = A4(
	$elm$json$Json$Decode$map3,
	F3(
		function (value, suit, deck) {
			return {originDeck: deck, suit: suit, value: value};
		}),
	A2(
		$elm$json$Json$Decode$field,
		'value',
		A2($author$project$Game$Card$intDecoderVia, $author$project$Game$Card$intToCardValue, 'card value')),
	A2(
		$elm$json$Json$Decode$field,
		'suit',
		A2($author$project$Game$Card$intDecoderVia, $author$project$Game$Card$intToSuit, 'suit')),
	A2(
		$elm$json$Json$Decode$field,
		'origin_deck',
		A2($author$project$Game$Card$intDecoderVia, $author$project$Game$Card$intToOriginDeck, 'origin_deck')));
var $author$project$Game$CardStack$intDecoderVia = F2(
	function (toMaybe, label) {
		return A2(
			$elm$json$Json$Decode$andThen,
			function (n) {
				var _v0 = toMaybe(n);
				if (_v0.$ === 'Just') {
					var a = _v0.a;
					return $elm$json$Json$Decode$succeed(a);
				} else {
					return $elm$json$Json$Decode$fail(
						'invalid ' + (label + (': ' + $elm$core$String$fromInt(n))));
				}
			},
			$elm$json$Json$Decode$int);
	});
var $author$project$Game$CardStack$FreshlyPlayed = {$: 'FreshlyPlayed'};
var $author$project$Game$CardStack$FreshlyPlayedByLastPlayer = {$: 'FreshlyPlayedByLastPlayer'};
var $author$project$Game$CardStack$intToBoardCardState = function (n) {
	switch (n) {
		case 0:
			return $elm$core$Maybe$Just($author$project$Game$CardStack$FirmlyOnBoard);
		case 1:
			return $elm$core$Maybe$Just($author$project$Game$CardStack$FreshlyPlayed);
		case 2:
			return $elm$core$Maybe$Just($author$project$Game$CardStack$FreshlyPlayedByLastPlayer);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$CardStack$boardCardDecoder = A3(
	$elm$json$Json$Decode$map2,
	F2(
		function (card, state) {
			return {card: card, state: state};
		}),
	A2($elm$json$Json$Decode$field, 'card', $author$project$Game$Card$cardDecoder),
	A2(
		$elm$json$Json$Decode$field,
		'state',
		A2($author$project$Game$CardStack$intDecoderVia, $author$project$Game$CardStack$intToBoardCardState, 'board card state')));
var $author$project$Game$CardStack$cardStackDecoder = A3(
	$elm$json$Json$Decode$map2,
	F2(
		function (boardCards, loc) {
			return {boardCards: boardCards, loc: loc};
		}),
	A2(
		$elm$json$Json$Decode$field,
		'board_cards',
		$elm$json$Json$Decode$list($author$project$Game$CardStack$boardCardDecoder)),
	A2($elm$json$Json$Decode$field, 'loc', $author$project$Game$CardStack$boardLocationDecoder));
var $author$project$Game$BoardActions$Left = {$: 'Left'};
var $author$project$Game$BoardActions$Right = {$: 'Right'};
var $author$project$Game$WireAction$sideDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (s) {
		switch (s) {
			case 'left':
				return $elm$json$Json$Decode$succeed($author$project$Game$BoardActions$Left);
			case 'right':
				return $elm$json$Json$Decode$succeed($author$project$Game$BoardActions$Right);
			default:
				var other = s;
				return $elm$json$Json$Decode$fail('Unknown side: ' + other);
		}
	},
	$elm$json$Json$Decode$string);
var $author$project$Game$WireAction$decoderForAction = function (kind) {
	switch (kind) {
		case 'split':
			return A3(
				$elm$json$Json$Decode$map2,
				F2(
					function (stack, cardIndex) {
						return $author$project$Game$WireAction$Split(
							{cardIndex: cardIndex, stack: stack});
					}),
				A2($elm$json$Json$Decode$field, 'stack', $author$project$Game$CardStack$cardStackDecoder),
				A2($elm$json$Json$Decode$field, 'card_index', $elm$json$Json$Decode$int));
		case 'merge_stack':
			return A4(
				$elm$json$Json$Decode$map3,
				F3(
					function (source, target, side) {
						return $author$project$Game$WireAction$MergeStack(
							{side: side, source: source, target: target});
					}),
				A2($elm$json$Json$Decode$field, 'source', $author$project$Game$CardStack$cardStackDecoder),
				A2($elm$json$Json$Decode$field, 'target', $author$project$Game$CardStack$cardStackDecoder),
				A2($elm$json$Json$Decode$field, 'side', $author$project$Game$WireAction$sideDecoder));
		case 'merge_hand':
			return A4(
				$elm$json$Json$Decode$map3,
				F3(
					function (handCard, target, side) {
						return $author$project$Game$WireAction$MergeHand(
							{handCard: handCard, side: side, target: target});
					}),
				A2($elm$json$Json$Decode$field, 'hand_card', $author$project$Game$Card$cardDecoder),
				A2($elm$json$Json$Decode$field, 'target', $author$project$Game$CardStack$cardStackDecoder),
				A2($elm$json$Json$Decode$field, 'side', $author$project$Game$WireAction$sideDecoder));
		case 'place_hand':
			return A3(
				$elm$json$Json$Decode$map2,
				F2(
					function (handCard, loc) {
						return $author$project$Game$WireAction$PlaceHand(
							{handCard: handCard, loc: loc});
					}),
				A2($elm$json$Json$Decode$field, 'hand_card', $author$project$Game$Card$cardDecoder),
				A2($elm$json$Json$Decode$field, 'loc', $author$project$Game$CardStack$boardLocationDecoder));
		case 'move_stack':
			return A3(
				$elm$json$Json$Decode$map2,
				F2(
					function (stack, newLoc) {
						return $author$project$Game$WireAction$MoveStack(
							{newLoc: newLoc, stack: stack});
					}),
				A2($elm$json$Json$Decode$field, 'stack', $author$project$Game$CardStack$cardStackDecoder),
				A2($elm$json$Json$Decode$field, 'new_loc', $author$project$Game$CardStack$boardLocationDecoder));
		case 'complete_turn':
			return $elm$json$Json$Decode$succeed($author$project$Game$WireAction$CompleteTurn);
		case 'undo':
			return $elm$json$Json$Decode$succeed($author$project$Game$WireAction$Undo);
		default:
			var other = kind;
			return $elm$json$Json$Decode$fail('Unknown action: ' + other);
	}
};
var $author$project$Game$WireAction$decoder = A2(
	$elm$json$Json$Decode$andThen,
	$author$project$Game$WireAction$decoderForAction,
	A2($elm$json$Json$Decode$field, 'action', $elm$json$Json$Decode$string));
var $author$project$Main$Wire$gesturePointDecoder = A4(
	$elm$json$Json$Decode$map3,
	F3(
		function (t, x, y) {
			return {tMs: t, x: x, y: y};
		}),
	A2($elm$json$Json$Decode$field, 't', $elm$json$Json$Decode$float),
	A2($elm$json$Json$Decode$field, 'x', $elm$json$Json$Decode$int),
	A2($elm$json$Json$Decode$field, 'y', $elm$json$Json$Decode$int));
var $elm$json$Json$Decode$oneOf = _Json_oneOf;
var $elm$json$Json$Decode$maybe = function (decoder) {
	return $elm$json$Json$Decode$oneOf(
		_List_fromArray(
			[
				A2($elm$json$Json$Decode$map, $elm$core$Maybe$Just, decoder),
				$elm$json$Json$Decode$succeed($elm$core$Maybe$Nothing)
			]));
};
var $author$project$Main$State$BoardFrame = {$: 'BoardFrame'};
var $author$project$Main$Wire$pathFrameDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (s) {
		switch (s) {
			case 'board':
				return $elm$json$Json$Decode$succeed($author$project$Main$State$BoardFrame);
			case 'viewport':
				return $elm$json$Json$Decode$succeed($author$project$Main$State$ViewportFrame);
			default:
				var other = s;
				return $elm$json$Json$Decode$fail('Unknown path_frame: ' + other);
		}
	},
	$elm$json$Json$Decode$string);
var $author$project$Main$Wire$actionLogEntryDecoder = A4(
	$elm$json$Json$Decode$map3,
	$author$project$Main$State$ActionLogEntry,
	A2($elm$json$Json$Decode$field, 'action', $author$project$Game$WireAction$decoder),
	$elm$json$Json$Decode$maybe(
		A2(
			$elm$json$Json$Decode$at,
			_List_fromArray(
				['gesture_metadata', 'path']),
			$elm$json$Json$Decode$list($author$project$Main$Wire$gesturePointDecoder))),
	$elm$json$Json$Decode$oneOf(
		_List_fromArray(
			[
				A2(
				$elm$json$Json$Decode$at,
				_List_fromArray(
					['gesture_metadata', 'path_frame']),
				$author$project$Main$Wire$pathFrameDecoder),
				$elm$json$Json$Decode$succeed($author$project$Main$State$ViewportFrame)
			])));
var $author$project$Main$State$RemoteState = F9(
	function (board, hands, scores, activePlayerIndex, turnIndex, deck, cardsPlayedThisTurn, victorAwarded, turnStartBoardScore) {
		return {activePlayerIndex: activePlayerIndex, board: board, cardsPlayedThisTurn: cardsPlayedThisTurn, deck: deck, hands: hands, scores: scores, turnIndex: turnIndex, turnStartBoardScore: turnStartBoardScore, victorAwarded: victorAwarded};
	});
var $elm$json$Json$Decode$bool = _Json_decodeBool;
var $author$project$Game$CardStack$BackFromBoard = {$: 'BackFromBoard'};
var $author$project$Game$CardStack$FreshlyDrawn = {$: 'FreshlyDrawn'};
var $author$project$Game$CardStack$intToHandCardState = function (n) {
	switch (n) {
		case 0:
			return $elm$core$Maybe$Just($author$project$Game$CardStack$HandNormal);
		case 1:
			return $elm$core$Maybe$Just($author$project$Game$CardStack$FreshlyDrawn);
		case 2:
			return $elm$core$Maybe$Just($author$project$Game$CardStack$BackFromBoard);
		default:
			return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$CardStack$handCardDecoder = A3(
	$elm$json$Json$Decode$map2,
	F2(
		function (card, state) {
			return {card: card, state: state};
		}),
	A2($elm$json$Json$Decode$field, 'card', $author$project$Game$Card$cardDecoder),
	A2(
		$elm$json$Json$Decode$field,
		'state',
		A2($author$project$Game$CardStack$intDecoderVia, $author$project$Game$CardStack$intToHandCardState, 'hand card state')));
var $author$project$Main$Wire$handDecoder = A2(
	$elm$json$Json$Decode$map,
	function (cards) {
		return {handCards: cards};
	},
	A2(
		$elm$json$Json$Decode$field,
		'hand_cards',
		$elm$json$Json$Decode$list($author$project$Game$CardStack$handCardDecoder)));
var $elm$json$Json$Decode$map8 = _Json_map8;
var $author$project$Main$Wire$initialStateDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (partial) {
		return A2(
			$elm$json$Json$Decode$map,
			partial,
			A2($elm$json$Json$Decode$field, 'turn_start_board_score', $elm$json$Json$Decode$int));
	},
	A9(
		$elm$json$Json$Decode$map8,
		$author$project$Main$State$RemoteState,
		A2(
			$elm$json$Json$Decode$field,
			'board',
			$elm$json$Json$Decode$list($author$project$Game$CardStack$cardStackDecoder)),
		A2(
			$elm$json$Json$Decode$field,
			'hands',
			$elm$json$Json$Decode$list($author$project$Main$Wire$handDecoder)),
		A2(
			$elm$json$Json$Decode$field,
			'scores',
			$elm$json$Json$Decode$list($elm$json$Json$Decode$int)),
		A2($elm$json$Json$Decode$field, 'active_player_index', $elm$json$Json$Decode$int),
		A2($elm$json$Json$Decode$field, 'turn_index', $elm$json$Json$Decode$int),
		A2(
			$elm$json$Json$Decode$field,
			'deck',
			$elm$json$Json$Decode$list($author$project$Game$Card$cardDecoder)),
		A2($elm$json$Json$Decode$field, 'cards_played_this_turn', $elm$json$Json$Decode$int),
		A2($elm$json$Json$Decode$field, 'victor_awarded', $elm$json$Json$Decode$bool)));
var $author$project$Main$Wire$actionLogDecoder = A3(
	$elm$json$Json$Decode$map2,
	$author$project$Main$State$ActionLogBundle,
	A2($elm$json$Json$Decode$field, 'initial_state', $author$project$Main$Wire$initialStateDecoder),
	A2(
		$elm$json$Json$Decode$field,
		'actions',
		$elm$json$Json$Decode$list($author$project$Main$Wire$actionLogEntryDecoder)));
var $author$project$Main$Wire$fetchActionLog = function (sid) {
	return $elm$http$Http$get(
		{
			expect: A2($elm$http$Http$expectJson, $author$project$Main$Msg$ActionLogFetched, $author$project$Main$Wire$actionLogDecoder),
			url: '/gopher/lynrummy-elm/sessions/' + ($elm$core$String$fromInt(sid) + '/actions')
		});
};
var $author$project$Main$Msg$SessionReceived = function (a) {
	return {$: 'SessionReceived', a: a};
};
var $elm$http$Http$post = function (r) {
	return $elm$http$Http$request(
		{body: r.body, expect: r.expect, headers: _List_Nil, method: 'POST', timeout: $elm$core$Maybe$Nothing, tracker: $elm$core$Maybe$Nothing, url: r.url});
};
var $author$project$Main$Wire$sessionIdDecoder = A2($elm$json$Json$Decode$field, 'session_id', $elm$json$Json$Decode$int);
var $author$project$Main$Wire$fetchNewSession = $elm$http$Http$post(
	{
		body: $elm$http$Http$emptyBody,
		expect: A2($elm$http$Http$expectJson, $author$project$Main$Msg$SessionReceived, $author$project$Main$Wire$sessionIdDecoder),
		url: '/gopher/lynrummy-elm/new-session'
	});
var $author$project$Main$Play$init = function (config) {
	switch (config.$) {
		case 'NewSession':
			return _Utils_Tuple2($author$project$Main$State$baseModel, $author$project$Main$Wire$fetchNewSession);
		case 'ResumeSession':
			var sid = config.a;
			return _Utils_Tuple2(
				_Utils_update(
					$author$project$Main$State$baseModel,
					{
						gameId: $elm$core$String$fromInt(sid),
						sessionId: $elm$core$Maybe$Just(sid),
						status: {
							kind: $author$project$Main$State$Inform,
							text: 'Resuming session ' + ($elm$core$String$fromInt(sid) + '…')
						}
					}),
				$author$project$Main$Wire$fetchActionLog(sid));
		default:
			var sessionId = config.a.sessionId;
			var puzzleName = config.a.puzzleName;
			var initialState = config.a.initialState;
			var framed = _Utils_update(
				$author$project$Main$State$baseModel,
				{
					gameId: puzzleName,
					hideTurnControls: true,
					puzzleName: $elm$core$Maybe$Just(puzzleName),
					sessionId: $elm$core$Maybe$Just(sessionId)
				});
			var _v1 = A2($elm$json$Json$Decode$decodeValue, $author$project$Main$Wire$initialStateDecoder, initialState);
			if (_v1.$ === 'Ok') {
				var decoded = _v1.a;
				return _Utils_Tuple2(
					A3($author$project$Main$Play$bootstrapPuzzle, decoded, puzzleName, framed),
					$elm$core$Platform$Cmd$none);
			} else {
				var err = _v1.a;
				return _Utils_Tuple2(
					_Utils_update(
						framed,
						{
							status: {
								kind: $author$project$Main$State$Scold,
								text: 'Puzzle ' + (puzzleName + (' failed to decode: ' + $elm$json$Json$Decode$errorToString(err)))
							}
						}),
					$elm$core$Platform$Cmd$none);
			}
	}
};
var $elm$core$Platform$Cmd$map = _Platform_map;
var $author$project$Lab$AnnotationSent = F2(
	function (a, b) {
		return {$: 'AnnotationSent', a: a, b: b};
	});
var $elm$http$Http$expectBytesResponse = F2(
	function (toMsg, toResult) {
		return A3(
			_Http_expect,
			'arraybuffer',
			_Http_toDataView,
			A2($elm$core$Basics$composeR, toResult, toMsg));
	});
var $elm$http$Http$expectWhatever = function (toMsg) {
	return A2(
		$elm$http$Http$expectBytesResponse,
		toMsg,
		$elm$http$Http$resolve(
			function (_v0) {
				return $elm$core$Result$Ok(_Utils_Tuple0);
			}));
};
var $elm$json$Json$Encode$int = _Json_wrap;
var $elm$http$Http$jsonBody = function (value) {
	return A2(
		_Http_pair,
		'application/json',
		A2($elm$json$Json$Encode$encode, 0, value));
};
var $elm$json$Json$Encode$object = function (pairs) {
	return _Json_wrap(
		A3(
			$elm$core$List$foldl,
			F2(
				function (_v0, obj) {
					var k = _v0.a;
					var v = _v0.b;
					return A3(_Json_addField, k, v, obj);
				}),
			_Json_emptyObject(_Utils_Tuple0),
			pairs));
};
var $elm$json$Json$Encode$string = _Json_wrap;
var $author$project$Lab$sendAnnotation = F4(
	function (sessionId, userName, puzzleName, body) {
		return $elm$http$Http$post(
			{
				body: $elm$http$Http$jsonBody(
					$elm$json$Json$Encode$object(
						_List_fromArray(
							[
								_Utils_Tuple2(
								'session_id',
								$elm$json$Json$Encode$int(sessionId)),
								_Utils_Tuple2(
								'puzzle_name',
								$elm$json$Json$Encode$string(puzzleName)),
								_Utils_Tuple2(
								'user_name',
								$elm$json$Json$Encode$string(userName)),
								_Utils_Tuple2(
								'body',
								$elm$json$Json$Encode$string(body))
							]))),
				expect: $elm$http$Http$expectWhatever(
					$author$project$Lab$AnnotationSent(puzzleName)),
				url: '/gopher/board-lab/annotate'
			});
	});
var $elm$core$String$trim = _String_trim;
var $author$project$Main$Play$NoOutput = {$: 'NoOutput'};
var $author$project$Main$Play$SessionChanged = function (a) {
	return {$: 'SessionChanged', a: a};
};
var $author$project$Main$State$Dragging = function (a) {
	return {$: 'Dragging', a: a};
};
var $elm$core$Debug$log = _Debug_log;
var $author$project$Main$Play$boardRectReceived = F2(
	function (result, model) {
		if (result.$ === 'Ok') {
			var element = result.a;
			var rect = {
				height: $elm$core$Basics$round(element.element.height),
				width: $elm$core$Basics$round(element.element.width),
				x: $elm$core$Basics$round(element.element.x - element.viewport.x),
				y: $elm$core$Basics$round(element.element.y - element.viewport.y)
			};
			var replayOffset = function () {
				var _v2 = model.replay;
				if (_v2.$ === 'Just') {
					return $elm$core$Maybe$Just(
						{x: rect.x, y: rect.y});
				} else {
					return model.replayBoardRect;
				}
			}();
			var updatedDrag = function () {
				var _v1 = model.drag;
				if (_v1.$ === 'Dragging') {
					var info = _v1.a;
					return $author$project$Main$State$Dragging(
						_Utils_update(
							info,
							{
								boardRect: $elm$core$Maybe$Just(rect)
							}));
				} else {
					var other = _v1;
					return other;
				}
			}();
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{drag: updatedDrag, replayBoardRect: replayOffset}),
				$elm$core$Platform$Cmd$none);
		} else {
			var err = result.a;
			var _v3 = A2($elm$core$Debug$log, 'BoardRectReceived err', err);
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		}
	});
var $author$project$Main$State$Celebrate = {$: 'Celebrate'};
var $author$project$Game$PlayerTurn$SuccessAsVictor = {$: 'SuccessAsVictor'};
var $author$project$Game$CardStack$boardCardAgedState = function (state) {
	switch (state.$) {
		case 'FreshlyPlayedByLastPlayer':
			return $author$project$Game$CardStack$FirmlyOnBoard;
		case 'FreshlyPlayed':
			return $author$project$Game$CardStack$FreshlyPlayedByLastPlayer;
		default:
			return $author$project$Game$CardStack$FirmlyOnBoard;
	}
};
var $author$project$Game$CardStack$agedFromPriorTurn = function (s) {
	return _Utils_update(
		s,
		{
			boardCards: A2(
				$elm$core$List$map,
				function (bc) {
					return _Utils_update(
						bc,
						{
							state: $author$project$Game$CardStack$boardCardAgedState(bc.state)
						});
				},
				s.boardCards)
		});
};
var $author$project$Game$Score$forCardsPlayed = function (num) {
	if (num <= 0) {
		return 0;
	} else {
		var progressivePointsForPlayedCards = (100 * num) * num;
		var actuallyPlayedBonus = 200;
		return actuallyPlayedBonus + progressivePointsForPlayedCards;
	}
};
var $author$project$Game$PlayerTurn$getScore = F2(
	function (currentBoardScore, t) {
		var cardsScore = $author$project$Game$Score$forCardsPlayed(t.cardsPlayedDuringTurn);
		var boardScore = currentBoardScore - t.startingBoardScore;
		return ((boardScore + cardsScore) + t.victoryBonus) + t.emptyHandBonus;
	});
var $elm$core$List$drop = F2(
	function (n, list) {
		drop:
		while (true) {
			if (n <= 0) {
				return list;
			} else {
				if (!list.b) {
					return list;
				} else {
					var x = list.a;
					var xs = list.b;
					var $temp$n = n - 1,
						$temp$list = xs;
					n = $temp$n;
					list = $temp$list;
					continue drop;
				}
			}
		}
	});
var $elm$core$List$head = function (list) {
	if (list.b) {
		var x = list.a;
		var xs = list.b;
		return $elm$core$Maybe$Just(x);
	} else {
		return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Game$Game$listAt = F2(
	function (i, xs) {
		return $elm$core$List$head(
			A2($elm$core$List$drop, i, xs));
	});
var $author$project$Game$PlayerTurn$new = function (startingBoardScore) {
	return {cardsPlayedDuringTurn: 0, emptyHandBonus: 0, startingBoardScore: startingBoardScore, victoryBonus: 0};
};
var $author$project$Game$Hand$resetState = function (h) {
	return _Utils_update(
		h,
		{
			handCards: A2(
				$elm$core$List$map,
				function (hc) {
					return _Utils_update(
						hc,
						{state: $author$project$Game$CardStack$HandNormal});
				},
				h.handCards)
		});
};
var $author$project$Game$Hand$size = function (h) {
	return $elm$core$List$length(h.handCards);
};
var $elm$core$List$takeReverse = F3(
	function (n, list, kept) {
		takeReverse:
		while (true) {
			if (n <= 0) {
				return kept;
			} else {
				if (!list.b) {
					return kept;
				} else {
					var x = list.a;
					var xs = list.b;
					var $temp$n = n - 1,
						$temp$list = xs,
						$temp$kept = A2($elm$core$List$cons, x, kept);
					n = $temp$n;
					list = $temp$list;
					kept = $temp$kept;
					continue takeReverse;
				}
			}
		}
	});
var $elm$core$List$takeTailRec = F2(
	function (n, list) {
		return $elm$core$List$reverse(
			A3($elm$core$List$takeReverse, n, list, _List_Nil));
	});
var $elm$core$List$takeFast = F3(
	function (ctr, n, list) {
		if (n <= 0) {
			return _List_Nil;
		} else {
			var _v0 = _Utils_Tuple2(n, list);
			_v0$1:
			while (true) {
				_v0$5:
				while (true) {
					if (!_v0.b.b) {
						return list;
					} else {
						if (_v0.b.b.b) {
							switch (_v0.a) {
								case 1:
									break _v0$1;
								case 2:
									var _v2 = _v0.b;
									var x = _v2.a;
									var _v3 = _v2.b;
									var y = _v3.a;
									return _List_fromArray(
										[x, y]);
								case 3:
									if (_v0.b.b.b.b) {
										var _v4 = _v0.b;
										var x = _v4.a;
										var _v5 = _v4.b;
										var y = _v5.a;
										var _v6 = _v5.b;
										var z = _v6.a;
										return _List_fromArray(
											[x, y, z]);
									} else {
										break _v0$5;
									}
								default:
									if (_v0.b.b.b.b && _v0.b.b.b.b.b) {
										var _v7 = _v0.b;
										var x = _v7.a;
										var _v8 = _v7.b;
										var y = _v8.a;
										var _v9 = _v8.b;
										var z = _v9.a;
										var _v10 = _v9.b;
										var w = _v10.a;
										var tl = _v10.b;
										return (ctr > 1000) ? A2(
											$elm$core$List$cons,
											x,
											A2(
												$elm$core$List$cons,
												y,
												A2(
													$elm$core$List$cons,
													z,
													A2(
														$elm$core$List$cons,
														w,
														A2($elm$core$List$takeTailRec, n - 4, tl))))) : A2(
											$elm$core$List$cons,
											x,
											A2(
												$elm$core$List$cons,
												y,
												A2(
													$elm$core$List$cons,
													z,
													A2(
														$elm$core$List$cons,
														w,
														A3($elm$core$List$takeFast, ctr + 1, n - 4, tl)))));
									} else {
										break _v0$5;
									}
							}
						} else {
							if (_v0.a === 1) {
								break _v0$1;
							} else {
								break _v0$5;
							}
						}
					}
				}
				return list;
			}
			var _v1 = _v0.b;
			var x = _v1.a;
			return _List_fromArray(
				[x]);
		}
	});
var $elm$core$List$take = F2(
	function (n, list) {
		return A3($elm$core$List$takeFast, 0, n, list);
	});
var $author$project$Game$Game$takeDeck = F2(
	function (n, deck) {
		return (n <= 0) ? _Utils_Tuple2(_List_Nil, deck) : _Utils_Tuple2(
			A2($elm$core$List$take, n, deck),
			A2($elm$core$List$drop, n, deck));
	});
var $author$project$Game$PlayerTurn$Success = {$: 'Success'};
var $author$project$Game$PlayerTurn$SuccessButNeedsCards = {$: 'SuccessButNeedsCards'};
var $author$project$Game$PlayerTurn$SuccessWithHandEmptied = {$: 'SuccessWithHandEmptied'};
var $author$project$Game$PlayerTurn$emptiedHand = function (t) {
	return t.emptyHandBonus > 0;
};
var $author$project$Game$PlayerTurn$getNumCardsPlayed = function (t) {
	return t.cardsPlayedDuringTurn;
};
var $author$project$Game$PlayerTurn$gotVictoryBonus = function (t) {
	return t.victoryBonus > 0;
};
var $author$project$Game$PlayerTurn$turnResult = function (t) {
	return (!$author$project$Game$PlayerTurn$getNumCardsPlayed(t)) ? $author$project$Game$PlayerTurn$SuccessButNeedsCards : ($author$project$Game$PlayerTurn$emptiedHand(t) ? ($author$project$Game$PlayerTurn$gotVictoryBonus(t) ? $author$project$Game$PlayerTurn$SuccessAsVictor : $author$project$Game$PlayerTurn$SuccessWithHandEmptied) : $author$project$Game$PlayerTurn$Success);
};
var $author$project$Game$PlayerTurn$updateScoreForEmptyHand = F2(
	function (isVictor, t) {
		return _Utils_update(
			t,
			{
				emptyHandBonus: 1000,
				victoryBonus: isVictor ? 500 : 0
			});
	});
var $author$project$Game$Game$applyCompleteTurn = function (state) {
	var turnBase = function () {
		var seed = $author$project$Game$PlayerTurn$new(state.turnStartBoardScore);
		return _Utils_update(
			seed,
			{cardsPlayedDuringTurn: state.cardsPlayedThisTurn});
	}();
	var outgoingIdx = state.activePlayerIndex;
	var outgoingHandSize = A2(
		$elm$core$Maybe$withDefault,
		0,
		A2(
			$elm$core$Maybe$map,
			$author$project$Game$Hand$size,
			A2($author$project$Game$Game$listAt, outgoingIdx, state.hands)));
	var turnWithBonuses = ((!outgoingHandSize) && (state.cardsPlayedThisTurn > 0)) ? A2($author$project$Game$PlayerTurn$updateScoreForEmptyHand, !state.victorAwarded, turnBase) : turnBase;
	var result = $author$project$Game$PlayerTurn$turnResult(turnWithBonuses);
	var nHands = A2(
		$elm$core$Basics$max,
		1,
		$elm$core$List$length(state.hands));
	var nextActive = A2($elm$core$Basics$modBy, nHands, outgoingIdx + 1);
	var drawCount = function () {
		switch (result.$) {
			case 'SuccessButNeedsCards':
				return 3;
			case 'SuccessAsVictor':
				return 5;
			case 'SuccessWithHandEmptied':
				return 5;
			case 'Success':
				return 0;
			default:
				return 0;
		}
	}();
	var boardScore = $author$project$Game$Score$forStacks(state.board);
	var turnScore = A2($author$project$Game$PlayerTurn$getScore, boardScore, turnWithBonuses);
	var newScores = A2(
		$elm$core$List$indexedMap,
		F2(
			function (i, s) {
				return _Utils_eq(i, outgoingIdx) ? (s + turnScore) : s;
			}),
		state.scores);
	var agedBoard = A2($elm$core$List$map, $author$project$Game$CardStack$agedFromPriorTurn, state.board);
	var _v0 = function () {
		var _v1 = A2($author$project$Game$Game$listAt, outgoingIdx, state.hands);
		if (_v1.$ === 'Just') {
			var h = _v1.a;
			var reset = $author$project$Game$Hand$resetState(h);
			var _v2 = A2($author$project$Game$Game$takeDeck, drawCount, state.deck);
			var cards = _v2.a;
			var leftover = _v2.b;
			var afterDraw = A3($author$project$Game$Hand$addCards, cards, $author$project$Game$CardStack$FreshlyDrawn, reset);
			return _Utils_Tuple3(afterDraw, leftover, cards);
		} else {
			return _Utils_Tuple3(
				{handCards: _List_Nil},
				state.deck,
				_List_Nil);
		}
	}();
	var newOutgoingHand = _v0.a;
	var remainingDeck = _v0.b;
	var drawnCards = _v0.c;
	var outcome = {cardsDrawn: drawCount, dealtCards: drawnCards, result: result, turnScore: turnScore};
	var newHands = A2(
		$elm$core$List$indexedMap,
		F2(
			function (i, h) {
				return _Utils_eq(i, outgoingIdx) ? newOutgoingHand : h;
			}),
		state.hands);
	var newState = _Utils_update(
		state,
		{
			activePlayerIndex: nextActive,
			board: agedBoard,
			cardsPlayedThisTurn: 0,
			deck: remainingDeck,
			hands: newHands,
			scores: newScores,
			turnIndex: state.turnIndex + 1,
			turnStartBoardScore: boardScore,
			victorAwarded: state.victorAwarded || _Utils_eq(result, $author$project$Game$PlayerTurn$SuccessAsVictor)
		});
	return _Utils_Tuple2(newState, outcome);
};
var $author$project$Main$Apply$applyCompleteTurn = function (model) {
	var _v0 = $author$project$Game$Game$applyCompleteTurn(model);
	var afterTurn = _v0.a;
	var withScore = _Utils_update(
		afterTurn,
		{
			score: $author$project$Game$Score$forStacks(afterTurn.board)
		});
	return {
		model: withScore,
		status: {
			kind: $author$project$Main$State$Celebrate,
			text: 'Turn ' + ($elm$core$String$fromInt(afterTurn.turnIndex + 1) + (' — Player ' + ($elm$core$String$fromInt(afterTurn.activePlayerIndex + 1) + ' to play.')))
		}
	};
};
var $author$project$Main$State$listAt = F2(
	function (i, xs) {
		return $elm$core$List$head(
			A2($elm$core$List$drop, i, xs));
	});
var $author$project$Main$State$activeHand = function (model) {
	var _v0 = A2($author$project$Main$State$listAt, model.activePlayerIndex, model.hands);
	if (_v0.$ === 'Just') {
		var h = _v0.a;
		return h;
	} else {
		return $author$project$Game$Hand$empty;
	}
};
var $elm$core$List$filter = F2(
	function (isGood, list) {
		return A3(
			$elm$core$List$foldr,
			F2(
				function (x, xs) {
					return isGood(x) ? A2($elm$core$List$cons, x, xs) : xs;
				}),
			_List_Nil,
			list);
	});
var $author$project$Game$CardStack$cardsEqualInOrder = F2(
	function (xs, ys) {
		var _v0 = _Utils_Tuple2(xs, ys);
		_v0$2:
		while (true) {
			if (!_v0.a.b) {
				if (!_v0.b.b) {
					return true;
				} else {
					break _v0$2;
				}
			} else {
				if (_v0.b.b) {
					var _v1 = _v0.a;
					var x = _v1.a;
					var xrest = _v1.b;
					var _v2 = _v0.b;
					var y = _v2.a;
					var yrest = _v2.b;
					return _Utils_eq(x.card, y.card) && A2($author$project$Game$CardStack$cardsEqualInOrder, xrest, yrest);
				} else {
					break _v0$2;
				}
			}
		}
		return false;
	});
var $author$project$Game$CardStack$locsEqual = F2(
	function (a, b) {
		return _Utils_eq(a.top, b.top) && _Utils_eq(a.left, b.left);
	});
var $author$project$Game$CardStack$stacksEqual = F2(
	function (a, b) {
		return A2($author$project$Game$CardStack$locsEqual, a.loc, b.loc) && A2($author$project$Game$CardStack$cardsEqualInOrder, a.boardCards, b.boardCards);
	});
var $author$project$Game$Reducer$applyChange = F2(
	function (change, board) {
		return _Utils_ap(
			A2(
				$elm$core$List$filter,
				function (s) {
					return !A2(
						$elm$core$List$any,
						$author$project$Game$CardStack$stacksEqual(s),
						change.stacksToRemove);
				},
				board),
			change.stacksToAdd);
	});
var $author$project$Game$CardStack$handCardSameCard = F2(
	function (a, b) {
		return _Utils_eq(a.card, b.card);
	});
var $author$project$Game$Reducer$findHandCard = F2(
	function (card, hand) {
		return $elm$core$List$head(
			A2(
				$elm$core$List$filter,
				function (hc) {
					return A2(
						$author$project$Game$CardStack$handCardSameCard,
						hc,
						{card: card, state: $author$project$Game$CardStack$HandNormal});
				},
				hand.handCards));
	});
var $author$project$Game$CardStack$findStack = F2(
	function (ref, board) {
		return $elm$core$List$head(
			A2(
				$elm$core$List$filter,
				$author$project$Game$CardStack$stacksEqual(ref),
				board));
	});
var $author$project$Game$BoardActions$moveStack = F2(
	function (stack, newLoc) {
		return {
			handCardsToRelease: _List_Nil,
			stacksToAdd: _List_fromArray(
				[
					_Utils_update(
					stack,
					{loc: newLoc})
				]),
			stacksToRemove: _List_fromArray(
				[stack])
		};
	});
var $author$project$Game$CardStack$fromHandCard = F2(
	function (hc, loc) {
		return {
			boardCards: _List_fromArray(
				[
					{card: hc.card, state: $author$project$Game$CardStack$FreshlyPlayed}
				]),
			loc: loc
		};
	});
var $author$project$Game$BoardActions$placeHandCard = F2(
	function (handCard, loc) {
		return {
			handCardsToRelease: _List_fromArray(
				[handCard]),
			stacksToAdd: _List_fromArray(
				[
					A2($author$project$Game$CardStack$fromHandCard, handCard, loc)
				]),
			stacksToRemove: _List_Nil
		};
	});
var $author$project$Game$Hand$removeFirstMatch = F2(
	function (target, cards) {
		if (!cards.b) {
			return _List_Nil;
		} else {
			var c = cards.a;
			var rest = cards.b;
			return A2($author$project$Game$CardStack$handCardSameCard, c, target) ? rest : A2(
				$elm$core$List$cons,
				c,
				A2($author$project$Game$Hand$removeFirstMatch, target, rest));
		}
	});
var $author$project$Game$Hand$removeHandCard = F2(
	function (target, h) {
		return _Utils_update(
			h,
			{
				handCards: A2($author$project$Game$Hand$removeFirstMatch, target, h.handCards)
			});
	});
var $author$project$Game$CardStack$cardWidth = 27;
var $elm$core$Basics$negate = function (n) {
	return -n;
};
var $author$project$Game$CardStack$leftSplit = F2(
	function (leftCount, s) {
		var rightSideOffset = (leftCount * ($author$project$Game$CardStack$cardWidth + 6)) + 8;
		var rightLoc = {left: s.loc.left + rightSideOffset, top: s.loc.top};
		var rightCards = A2($elm$core$List$drop, leftCount, s.boardCards);
		var leftSideOffset = -2;
		var leftLoc = {left: s.loc.left + leftSideOffset, top: s.loc.top - 4};
		var leftCards = A2($elm$core$List$take, leftCount, s.boardCards);
		return _List_fromArray(
			[
				{boardCards: leftCards, loc: leftLoc},
				{boardCards: rightCards, loc: rightLoc}
			]);
	});
var $author$project$Game$CardStack$rightSplit = F2(
	function (leftCount, s) {
		var rightSideOffset = (leftCount * ($author$project$Game$CardStack$cardWidth + 6)) + 4;
		var rightLoc = {left: s.loc.left + rightSideOffset, top: s.loc.top - 4};
		var rightCards = A2($elm$core$List$drop, leftCount, s.boardCards);
		var leftSideOffset = -8;
		var leftLoc = {left: s.loc.left + leftSideOffset, top: s.loc.top};
		var leftCards = A2($elm$core$List$take, leftCount, s.boardCards);
		return _List_fromArray(
			[
				{boardCards: leftCards, loc: leftLoc},
				{boardCards: rightCards, loc: rightLoc}
			]);
	});
var $author$project$Game$CardStack$split = F2(
	function (cardIndex, s) {
		return ($author$project$Game$CardStack$size(s) <= 1) ? _List_fromArray(
			[s]) : ((_Utils_cmp(
			cardIndex + 1,
			($author$project$Game$CardStack$size(s) / 2) | 0) < 1) ? A2($author$project$Game$CardStack$leftSplit, cardIndex + 1, s) : A2($author$project$Game$CardStack$rightSplit, cardIndex, s));
	});
var $author$project$Game$BoardActions$dummyLoc = {left: -1, top: -1};
var $author$project$Game$CardStack$problematic = function (s) {
	var _v0 = $author$project$Game$CardStack$stackType(s);
	switch (_v0.$) {
		case 'Bogus':
			return true;
		case 'Dup':
			return true;
		default:
			return false;
	}
};
var $author$project$Game$CardStack$maybeMerge = F3(
	function (s1, s2, loc) {
		if (A2($author$project$Game$CardStack$stacksEqual, s1, s2)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var merged = {
				boardCards: _Utils_ap(s1.boardCards, s2.boardCards),
				loc: loc
			};
			return $author$project$Game$CardStack$problematic(merged) ? $elm$core$Maybe$Nothing : $elm$core$Maybe$Just(merged);
		}
	});
var $author$project$Game$CardStack$leftMerge = F2(
	function (self, other) {
		var loc = {
			left: self.loc.left - (($author$project$Game$CardStack$cardWidth + 6) * $author$project$Game$CardStack$size(other)),
			top: self.loc.top
		};
		return A3($author$project$Game$CardStack$maybeMerge, other, self, loc);
	});
var $author$project$Game$CardStack$rightMerge = F2(
	function (self, other) {
		var loc = {left: self.loc.left, top: self.loc.top};
		return A3($author$project$Game$CardStack$maybeMerge, self, other, loc);
	});
var $author$project$Game$BoardActions$tryMerge = F3(
	function (stack, other, side) {
		if (side.$ === 'Left') {
			return A2($author$project$Game$CardStack$leftMerge, stack, other);
		} else {
			return A2($author$project$Game$CardStack$rightMerge, stack, other);
		}
	});
var $author$project$Game$BoardActions$tryHandMerge = F3(
	function (stack, handCard, side) {
		var handStack = A2($author$project$Game$CardStack$fromHandCard, handCard, $author$project$Game$BoardActions$dummyLoc);
		var _v0 = A3($author$project$Game$BoardActions$tryMerge, stack, handStack, side);
		if (_v0.$ === 'Nothing') {
			return $elm$core$Maybe$Nothing;
		} else {
			var merged = _v0.a;
			return $elm$core$Maybe$Just(
				{
					handCardsToRelease: _List_fromArray(
						[handCard]),
					stacksToAdd: _List_fromArray(
						[merged]),
					stacksToRemove: _List_fromArray(
						[stack])
				});
		}
	});
var $author$project$Game$BoardActions$tryStackMerge = F3(
	function (stack, other, side) {
		var _v0 = A3($author$project$Game$BoardActions$tryMerge, stack, other, side);
		if (_v0.$ === 'Nothing') {
			return $elm$core$Maybe$Nothing;
		} else {
			var merged = _v0.a;
			return $elm$core$Maybe$Just(
				{
					handCardsToRelease: _List_Nil,
					stacksToAdd: _List_fromArray(
						[merged]),
					stacksToRemove: _List_fromArray(
						[stack, other])
				});
		}
	});
var $author$project$Game$Reducer$applyAction = F2(
	function (action, state) {
		switch (action.$) {
			case 'Split':
				var stack = action.a.stack;
				var cardIndex = action.a.cardIndex;
				var _v1 = A2($author$project$Game$CardStack$findStack, stack, state.board);
				if (_v1.$ === 'Just') {
					var real = _v1.a;
					return _Utils_update(
						state,
						{
							board: _Utils_ap(
								A2(
									$elm$core$List$filter,
									A2(
										$elm$core$Basics$composeL,
										$elm$core$Basics$not,
										$author$project$Game$CardStack$stacksEqual(real)),
									state.board),
								A2($author$project$Game$CardStack$split, cardIndex, real))
						});
				} else {
					return state;
				}
			case 'MergeStack':
				var source = action.a.source;
				var target = action.a.target;
				var side = action.a.side;
				var _v2 = _Utils_Tuple2(
					A2($author$project$Game$CardStack$findStack, source, state.board),
					A2($author$project$Game$CardStack$findStack, target, state.board));
				if ((_v2.a.$ === 'Just') && (_v2.b.$ === 'Just')) {
					var realSource = _v2.a.a;
					var realTarget = _v2.b.a;
					var _v3 = A3($author$project$Game$BoardActions$tryStackMerge, realTarget, realSource, side);
					if (_v3.$ === 'Just') {
						var change = _v3.a;
						return _Utils_update(
							state,
							{
								board: A2($author$project$Game$Reducer$applyChange, change, state.board)
							});
					} else {
						return state;
					}
				} else {
					return state;
				}
			case 'MergeHand':
				var handCard = action.a.handCard;
				var target = action.a.target;
				var side = action.a.side;
				var _v4 = A2($author$project$Game$CardStack$findStack, target, state.board);
				if (_v4.$ === 'Just') {
					var realTarget = _v4.a;
					var _v5 = function () {
						var _v6 = A2($author$project$Game$Reducer$findHandCard, handCard, state.hand);
						if (_v6.$ === 'Just') {
							var real = _v6.a;
							return _Utils_Tuple2(real, true);
						} else {
							return _Utils_Tuple2(
								{card: handCard, state: $author$project$Game$CardStack$HandNormal},
								false);
						}
					}();
					var hc = _v5.a;
					var mutateHand = _v5.b;
					var _v7 = A3($author$project$Game$BoardActions$tryHandMerge, realTarget, hc, side);
					if (_v7.$ === 'Just') {
						var change = _v7.a;
						return _Utils_update(
							state,
							{
								board: A2($author$project$Game$Reducer$applyChange, change, state.board),
								hand: mutateHand ? A2($author$project$Game$Hand$removeHandCard, hc, state.hand) : state.hand
							});
					} else {
						return state;
					}
				} else {
					return state;
				}
			case 'PlaceHand':
				var handCard = action.a.handCard;
				var loc = action.a.loc;
				var _v8 = A2($author$project$Game$Reducer$findHandCard, handCard, state.hand);
				if (_v8.$ === 'Just') {
					var hc = _v8.a;
					var change = A2($author$project$Game$BoardActions$placeHandCard, hc, loc);
					return _Utils_update(
						state,
						{
							board: A2($author$project$Game$Reducer$applyChange, change, state.board),
							hand: A2($author$project$Game$Hand$removeHandCard, hc, state.hand)
						});
				} else {
					return state;
				}
			case 'MoveStack':
				var stack = action.a.stack;
				var newLoc = action.a.newLoc;
				var _v9 = A2($author$project$Game$CardStack$findStack, stack, state.board);
				if (_v9.$ === 'Just') {
					var real = _v9.a;
					var change = A2($author$project$Game$BoardActions$moveStack, real, newLoc);
					return _Utils_update(
						state,
						{
							board: A2($author$project$Game$Reducer$applyChange, change, state.board)
						});
				} else {
					return state;
				}
			case 'CompleteTurn':
				return state;
			default:
				return state;
		}
	});
var $author$project$Main$State$setActiveHand = F2(
	function (newHand, model) {
		return _Utils_update(
			model,
			{
				hands: A2(
					$elm$core$List$indexedMap,
					F2(
						function (i, h) {
							return _Utils_eq(i, model.activePlayerIndex) ? newHand : h;
						}),
					model.hands)
			});
	});
var $author$project$Main$Apply$applyPhysics = F2(
	function (action, model) {
		var pre = {
			board: model.board,
			hand: $author$project$Main$State$activeHand(model)
		};
		var post = A2($author$project$Game$Reducer$applyAction, action, pre);
		return A2(
			$author$project$Main$State$setActiveHand,
			post.hand,
			_Utils_update(
				model,
				{
					board: post.board,
					score: $author$project$Game$Score$forStacks(post.board)
				}));
	});
var $author$project$Main$Apply$cleanBoardMessage = F2(
	function (prefix, post) {
		var delta = post.score - post.turnStartBoardScore;
		return prefix + (' Your board delta for this turn is ' + ($elm$core$String$fromInt(delta) + '.'));
	});
var $elm$core$List$all = F2(
	function (isOkay, list) {
		return !A2(
			$elm$core$List$any,
			A2($elm$core$Basics$composeL, $elm$core$Basics$not, isOkay),
			list);
	});
var $author$project$Main$Apply$isCompleteType = function (t) {
	switch (t.$) {
		case 'Set':
			return true;
		case 'PureRun':
			return true;
		case 'RedBlackRun':
			return true;
		case 'Incomplete':
			return false;
		case 'Bogus':
			return false;
		default:
			return false;
	}
};
var $author$project$Main$Apply$stackCards = function (stack) {
	return A2(
		$elm$core$List$map,
		function ($) {
			return $.card;
		},
		stack.boardCards);
};
var $author$project$Main$Apply$isCleanBoard = function (board) {
	return A2(
		$elm$core$List$all,
		A2(
			$elm$core$Basics$composeR,
			$author$project$Main$Apply$stackCards,
			A2($elm$core$Basics$composeR, $author$project$Game$StackType$getStackType, $author$project$Main$Apply$isCompleteType)),
		board);
};
var $author$project$Main$Apply$mergeStatus = function (post) {
	var _v0 = $elm$core$List$reverse(post.board);
	if (!_v0.b) {
		return {kind: $author$project$Main$State$Inform, text: 'Merged.'};
	} else {
		var mergedStack = _v0.a;
		return ($author$project$Game$CardStack$size(mergedStack) < 3) ? {kind: $author$project$Main$State$Scold, text: 'Nice, but where\'s the third card?'} : ($author$project$Main$Apply$isCleanBoard(post.board) ? {
			kind: $author$project$Main$State$Celebrate,
			text: A2($author$project$Main$Apply$cleanBoardMessage, 'Combined! Clean board!', post)
		} : {kind: $author$project$Main$State$Celebrate, text: 'Combined!'});
	}
};
var $author$project$Main$Apply$moveStackStatus = {kind: $author$project$Main$State$Inform, text: 'Moved!'};
var $author$project$Game$Game$noteCardsPlayed = F2(
	function (n, state) {
		return _Utils_update(
			state,
			{cardsPlayedThisTurn: state.cardsPlayedThisTurn + n});
	});
var $author$project$Main$Apply$placeHandStatus = {kind: $author$project$Main$State$Inform, text: 'On the board!'};
var $author$project$Main$Apply$splitStatus = {kind: $author$project$Main$State$Scold, text: 'Be careful with splitting! Splits only pay off when you get more cards on the board or make prettier piles.'};
var $author$project$Main$Apply$undoStatus = {kind: $author$project$Main$State$Inform, text: 'Undone.'};
var $author$project$Game$BoardGeometry$CleanlySpaced = {$: 'CleanlySpaced'};
var $author$project$Game$BoardGeometry$Crowded = {$: 'Crowded'};
var $author$project$Game$BoardGeometry$Illegal = {$: 'Illegal'};
var $author$project$Game$BoardGeometry$OutOfBounds = {$: 'OutOfBounds'};
var $author$project$Game$BoardGeometry$Overlap = {$: 'Overlap'};
var $author$project$Game$BoardGeometry$TooClose = {$: 'TooClose'};
var $author$project$Game$BoardGeometry$checkBounds = F2(
	function (bounds, _v0) {
		var i = _v0.a;
		var r = _v0.b;
		return ((r.left < 0) || ((r.top < 0) || ((_Utils_cmp(r.right, bounds.maxWidth) > 0) || (_Utils_cmp(r.bottom, bounds.maxHeight) > 0)))) ? $elm$core$Maybe$Just(
			{
				kind: $author$project$Game$BoardGeometry$OutOfBounds,
				message: 'Stack ' + ($elm$core$String$fromInt(i) + (' extends outside the board (rect: ' + ($elm$core$String$fromInt(r.left) + (',' + ($elm$core$String$fromInt(r.top) + (' → ' + ($elm$core$String$fromInt(r.right) + (',' + ($elm$core$String$fromInt(r.bottom) + (', bounds: ' + ($elm$core$String$fromInt(bounds.maxWidth) + ('x' + ($elm$core$String$fromInt(bounds.maxHeight) + ')'))))))))))))),
				stackIndices: _List_fromArray(
					[i])
			}) : $elm$core$Maybe$Nothing;
	});
var $author$project$Game$BoardGeometry$padRect = F2(
	function (margin, r) {
		return {bottom: r.bottom + margin, left: r.left - margin, right: r.right + margin, top: r.top - margin};
	});
var $author$project$Game$BoardGeometry$rectsOverlap = F2(
	function (a, b) {
		return (_Utils_cmp(a.left, b.right) < 0) && ((_Utils_cmp(a.right, b.left) > 0) && ((_Utils_cmp(a.top, b.bottom) < 0) && (_Utils_cmp(a.bottom, b.top) > 0)));
	});
var $author$project$Game$BoardGeometry$checkPair = F3(
	function (margin, _v0, _v1) {
		var i = _v0.a;
		var a = _v0.b;
		var j = _v1.a;
		var b = _v1.b;
		return A2($author$project$Game$BoardGeometry$rectsOverlap, a, b) ? $elm$core$Maybe$Just(
			{
				kind: $author$project$Game$BoardGeometry$Overlap,
				message: 'Stacks ' + ($elm$core$String$fromInt(i) + (' and ' + ($elm$core$String$fromInt(j) + ' overlap'))),
				stackIndices: _List_fromArray(
					[i, j])
			}) : (A2(
			$author$project$Game$BoardGeometry$rectsOverlap,
			A2($author$project$Game$BoardGeometry$padRect, margin, a),
			b) ? $elm$core$Maybe$Just(
			{
				kind: $author$project$Game$BoardGeometry$TooClose,
				message: 'Stacks ' + ($elm$core$String$fromInt(i) + (' and ' + ($elm$core$String$fromInt(j) + (' are too close (within ' + ($elm$core$String$fromInt(margin) + 'px margin)'))))),
				stackIndices: _List_fromArray(
					[i, j])
			}) : $elm$core$Maybe$Nothing);
	});
var $author$project$Game$BoardGeometry$collectPairErrors = F2(
	function (margin, rects) {
		if (!rects.b) {
			return _List_Nil;
		} else {
			var head = rects.a;
			var rest = rects.b;
			var fromHead = A2(
				$elm$core$List$filterMap,
				A2($author$project$Game$BoardGeometry$checkPair, margin, head),
				rest);
			return _Utils_ap(
				fromHead,
				A2($author$project$Game$BoardGeometry$collectPairErrors, margin, rest));
		}
	});
var $author$project$Game$BoardGeometry$cardHeight = 40;
var $author$project$Game$BoardGeometry$cardPitch = $author$project$Game$CardStack$cardWidth + 6;
var $author$project$Game$BoardGeometry$stackWidth = function (cardCount) {
	return (cardCount <= 0) ? 0 : ($author$project$Game$CardStack$cardWidth + ((cardCount - 1) * $author$project$Game$BoardGeometry$cardPitch));
};
var $author$project$Game$BoardGeometry$stackRect = function (s) {
	return {
		bottom: s.loc.top + $author$project$Game$BoardGeometry$cardHeight,
		left: s.loc.left,
		right: s.loc.left + $author$project$Game$BoardGeometry$stackWidth(
			$author$project$Game$CardStack$size(s)),
		top: s.loc.top
	};
};
var $author$project$Game$BoardGeometry$validateBoardGeometry = F2(
	function (stacks, bounds) {
		var rects = A2(
			$elm$core$List$indexedMap,
			F2(
				function (i, s) {
					return _Utils_Tuple2(
						i,
						$author$project$Game$BoardGeometry$stackRect(s));
				}),
			stacks);
		var pairErrors = A2($author$project$Game$BoardGeometry$collectPairErrors, bounds.margin, rects);
		var boundsErrors = A2(
			$elm$core$List$filterMap,
			$author$project$Game$BoardGeometry$checkBounds(bounds),
			rects);
		return _Utils_ap(boundsErrors, pairErrors);
	});
var $author$project$Game$BoardGeometry$classifyBoardGeometry = F2(
	function (stacks, bounds) {
		var isIllegalKind = function (kind) {
			return _Utils_eq(kind, $author$project$Game$BoardGeometry$OutOfBounds) || _Utils_eq(kind, $author$project$Game$BoardGeometry$Overlap);
		};
		var errors = A2($author$project$Game$BoardGeometry$validateBoardGeometry, stacks, bounds);
		return A2(
			$elm$core$List$any,
			function (e) {
				return isIllegalKind(e.kind);
			},
			errors) ? $author$project$Game$BoardGeometry$Illegal : (A2(
			$elm$core$List$any,
			function (e) {
				return _Utils_eq(e.kind, $author$project$Game$BoardGeometry$TooClose);
			},
			errors) ? $author$project$Game$BoardGeometry$Crowded : $author$project$Game$BoardGeometry$CleanlySpaced);
	});
var $author$project$Main$Apply$refereeBounds = {margin: 7, maxHeight: 600, maxWidth: 800};
var $author$project$Main$Apply$withTidinessOverlay = F3(
	function (pre, post, primary) {
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$BoardGeometry$classifyBoardGeometry, pre.board, $author$project$Main$Apply$refereeBounds),
			A2($author$project$Game$BoardGeometry$classifyBoardGeometry, post.board, $author$project$Main$Apply$refereeBounds));
		_v0$2:
		while (true) {
			switch (_v0.b.$) {
				case 'CleanlySpaced':
					if (_v0.a.$ === 'Crowded') {
						var _v1 = _v0.a;
						var _v2 = _v0.b;
						return {kind: $author$project$Main$State$Celebrate, text: 'Nice and tidy!'};
					} else {
						break _v0$2;
					}
				case 'Crowded':
					var _v3 = _v0.b;
					return {kind: $author$project$Main$State$Scold, text: 'Board is getting tight — try spacing stacks out!'};
				default:
					break _v0$2;
			}
		}
		return primary;
	});
var $author$project$Main$Apply$applyAction = F2(
	function (action, model) {
		switch (action.$) {
			case 'Split':
				var next = A2($author$project$Main$Apply$applyPhysics, action, model);
				return {
					model: next,
					status: A3($author$project$Main$Apply$withTidinessOverlay, model, next, $author$project$Main$Apply$splitStatus)
				};
			case 'MergeStack':
				var next = A2($author$project$Main$Apply$applyPhysics, action, model);
				return {
					model: next,
					status: A3(
						$author$project$Main$Apply$withTidinessOverlay,
						model,
						next,
						$author$project$Main$Apply$mergeStatus(next))
				};
			case 'MergeHand':
				var next = A2(
					$author$project$Game$Game$noteCardsPlayed,
					1,
					A2($author$project$Main$Apply$applyPhysics, action, model));
				return {
					model: next,
					status: A3(
						$author$project$Main$Apply$withTidinessOverlay,
						model,
						next,
						$author$project$Main$Apply$mergeStatus(next))
				};
			case 'PlaceHand':
				var next = A2(
					$author$project$Game$Game$noteCardsPlayed,
					1,
					A2($author$project$Main$Apply$applyPhysics, action, model));
				return {
					model: next,
					status: A3($author$project$Main$Apply$withTidinessOverlay, model, next, $author$project$Main$Apply$placeHandStatus)
				};
			case 'MoveStack':
				var next = A2($author$project$Main$Apply$applyPhysics, action, model);
				return {
					model: next,
					status: A3($author$project$Main$Apply$withTidinessOverlay, model, next, $author$project$Main$Apply$moveStackStatus)
				};
			case 'CompleteTurn':
				return $author$project$Main$Apply$applyCompleteTurn(model);
			default:
				return {model: model, status: $author$project$Main$Apply$undoStatus};
		}
	});
var $author$project$Main$Play$bootstrapFromBundle = F2(
	function (bundle, model) {
		var atInitial = A2(
			$author$project$Main$Play$modelAtInitial,
			bundle.initialState,
			_Utils_update(
				model,
				{actionLog: bundle.actions}));
		return A3(
			$elm$core$List$foldl,
			F2(
				function (entry, m) {
					return function ($) {
						return $.model;
					}(
						A2($author$project$Main$Apply$applyAction, entry.action, m));
				}),
			atInitial,
			bundle.actions);
	});
var $author$project$Game$Agent$Enumerator$initialLineage = function (state) {
	return _Utils_ap(state.trouble, state.growing);
};
var $elm$core$List$isEmpty = function (xs) {
	if (!xs.b) {
		return true;
	} else {
		return false;
	}
};
var $elm$core$List$sortBy = _List_sortBy;
var $author$project$Game$Agent$Buckets$troubleCount = function (_v0) {
	var trouble = _v0.trouble;
	var growing = _v0.growing;
	return $elm$core$List$sum(
		A2($elm$core$List$map, $elm$core$List$length, trouble)) + $elm$core$List$sum(
		A2($elm$core$List$map, $elm$core$List$length, growing));
};
var $author$project$Game$Agent$Bfs$Continue = F2(
	function (a, b) {
		return {$: 'Continue', a: a, b: b};
	});
var $author$project$Game$Agent$Bfs$Found = function (a) {
	return {$: 'Found', a: a};
};
var $elm$core$List$append = F2(
	function (xs, ys) {
		if (!ys.b) {
			return xs;
		} else {
			return A3($elm$core$List$foldr, $elm$core$List$cons, ys, xs);
		}
	});
var $elm$core$List$concat = function (lists) {
	return A3($elm$core$List$foldr, $elm$core$List$append, _List_Nil, lists);
};
var $elm$core$List$concatMap = F2(
	function (f, list) {
		return $elm$core$List$concat(
			A2($elm$core$List$map, f, list));
	});
var $elm$core$Set$Set_elm_builtin = function (a) {
	return {$: 'Set_elm_builtin', a: a};
};
var $elm$core$Set$empty = $elm$core$Set$Set_elm_builtin($elm$core$Dict$empty);
var $elm$core$Set$insert = F2(
	function (key, _v0) {
		var dict = _v0.a;
		return $elm$core$Set$Set_elm_builtin(
			A3($elm$core$Dict$insert, key, _Utils_Tuple0, dict));
	});
var $elm$core$Set$fromList = function (list) {
	return A3($elm$core$List$foldl, $elm$core$Set$insert, $elm$core$Set$empty, list);
};
var $author$project$Game$Card$cardValueToInt = function (v) {
	switch (v.$) {
		case 'Ace':
			return 1;
		case 'Two':
			return 2;
		case 'Three':
			return 3;
		case 'Four':
			return 4;
		case 'Five':
			return 5;
		case 'Six':
			return 6;
		case 'Seven':
			return 7;
		case 'Eight':
			return 8;
		case 'Nine':
			return 9;
		case 'Ten':
			return 10;
		case 'Jack':
			return 11;
		case 'Queen':
			return 12;
		default:
			return 13;
	}
};
var $author$project$Game$Card$suitToInt = function (s) {
	switch (s.$) {
		case 'Club':
			return 0;
		case 'Diamond':
			return 1;
		case 'Spade':
			return 2;
		default:
			return 3;
	}
};
var $author$project$Game$Agent$Enumerator$shapeOfCard = function (c) {
	return _Utils_Tuple2(
		$author$project$Game$Card$cardValueToInt(c.value),
		$author$project$Game$Card$suitToInt(c.suit));
};
var $author$project$Game$Agent$Enumerator$completionInventory = function (state) {
	var troubleSingletonShapes = A2(
		$elm$core$List$concatMap,
		$elm$core$List$map($author$project$Game$Agent$Enumerator$shapeOfCard),
		A2(
			$elm$core$List$filter,
			function (s) {
				return $elm$core$List$length(s) === 1;
			},
			state.trouble));
	var helperShapes = A2(
		$elm$core$List$concatMap,
		$elm$core$List$map($author$project$Game$Agent$Enumerator$shapeOfCard),
		state.helper);
	return $elm$core$Set$fromList(
		_Utils_ap(helperShapes, troubleSingletonShapes));
};
var $author$project$Game$Agent$Move$LeftSide = {$: 'LeftSide'};
var $author$project$Game$Agent$Move$Push = function (a) {
	return {$: 'Push', a: a};
};
var $author$project$Game$Agent$Move$RightSide = {$: 'RightSide'};
var $author$project$Game$Agent$Enumerator$dropAt = F2(
	function (i, xs) {
		return _Utils_ap(
			A2($elm$core$List$take, i, xs),
			A2($elm$core$List$drop, i + 1, xs));
	});
var $author$project$Game$Agent$Cards$isLegalStack = function (stack) {
	var _v0 = $author$project$Game$StackType$getStackType(stack);
	switch (_v0.$) {
		case 'Set':
			return true;
		case 'PureRun':
			return true;
		case 'RedBlackRun':
			return true;
		default:
			return false;
	}
};
var $author$project$Game$Agent$Enumerator$engulfFromGrowing = F3(
	function (state, gi, g) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var hi = _v0.a;
				var h = _v0.b;
				return A2(
					$elm$core$List$filterMap,
					function (side) {
						var merged = function () {
							if (side.$ === 'RightSide') {
								return _Utils_ap(h, g);
							} else {
								return _Utils_ap(g, h);
							}
						}();
						if (!$author$project$Game$Agent$Cards$isLegalStack(merged)) {
							return $elm$core$Maybe$Nothing;
						} else {
							var newState = {
								complete: _Utils_ap(
									state.complete,
									_List_fromArray(
										[merged])),
								growing: A2($author$project$Game$Agent$Enumerator$dropAt, gi, state.growing),
								helper: A2($author$project$Game$Agent$Enumerator$dropAt, hi, state.helper),
								trouble: state.trouble
							};
							var desc = {result: merged, side: side, targetBefore: h, troubleBefore: g};
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(
									$author$project$Game$Agent$Move$Push(desc),
									newState));
						}
					},
					_List_fromArray(
						[$author$project$Game$Agent$Move$RightSide, $author$project$Game$Agent$Move$LeftSide]));
			},
			A2(
				$elm$core$List$indexedMap,
				F2(
					function (hi, h) {
						return _Utils_Tuple2(hi, h);
					}),
				state.helper));
	});
var $author$project$Game$Agent$Enumerator$engulfMoves = function (state) {
	return A2(
		$elm$core$List$concatMap,
		function (_v0) {
			var gi = _v0.a;
			var g = _v0.b;
			return A3($author$project$Game$Agent$Enumerator$engulfFromGrowing, state, gi, g);
		},
		A2(
			$elm$core$List$indexedMap,
			F2(
				function (gi, g) {
					return _Utils_Tuple2(gi, g);
				}),
			state.growing));
};
var $author$project$Game$Agent$Move$Trouble = {$: 'Trouble'};
var $author$project$Game$Agent$Move$FreePull = function (a) {
	return {$: 'FreePull', a: a};
};
var $author$project$Game$Card$allSuits = _List_fromArray(
	[$author$project$Game$Card$Heart, $author$project$Game$Card$Spade, $author$project$Game$Card$Diamond, $author$project$Game$Card$Club]);
var $author$project$Game$Agent$Enumerator$completionShapes = function (partial) {
	if ((partial.b && partial.b.b) && (!partial.b.b.b)) {
		var c1 = partial.a;
		var _v1 = partial.b;
		var c2 = _v1.a;
		var v2 = $author$project$Game$Card$cardValueToInt(c2.value);
		var v1 = $author$project$Game$Card$cardValueToInt(c1.value);
		if (_Utils_eq(v1, v2)) {
			return $elm$core$Set$fromList(
				A2(
					$elm$core$List$map,
					function (s) {
						return _Utils_Tuple2(
							v1,
							$author$project$Game$Card$suitToInt(s));
					},
					A2(
						$elm$core$List$filter,
						function (s) {
							return (!_Utils_eq(s, c1.suit)) && (!_Utils_eq(s, c2.suit));
						},
						$author$project$Game$Card$allSuits)));
		} else {
			var succV = (v2 === 13) ? 1 : (v2 + 1);
			var predV = (v1 === 1) ? 13 : (v1 - 1);
			if (_Utils_eq(c1.suit, c2.suit)) {
				return $elm$core$Set$fromList(
					_List_fromArray(
						[
							_Utils_Tuple2(
							predV,
							$author$project$Game$Card$suitToInt(c1.suit)),
							_Utils_Tuple2(
							succV,
							$author$project$Game$Card$suitToInt(c2.suit))
						]));
			} else {
				var c2Color = $author$project$Game$Card$cardColor(c2);
				var succShapes = A2(
					$elm$core$List$map,
					function (s) {
						return _Utils_Tuple2(
							succV,
							$author$project$Game$Card$suitToInt(s));
					},
					A2(
						$elm$core$List$filter,
						function (s) {
							return !_Utils_eq(
								$author$project$Game$Card$suitColor(s),
								c2Color);
						},
						$author$project$Game$Card$allSuits));
				var c1Color = $author$project$Game$Card$cardColor(c1);
				var predShapes = A2(
					$elm$core$List$map,
					function (s) {
						return _Utils_Tuple2(
							predV,
							$author$project$Game$Card$suitToInt(s));
					},
					A2(
						$elm$core$List$filter,
						function (s) {
							return !_Utils_eq(
								$author$project$Game$Card$suitColor(s),
								c1Color);
						},
						$author$project$Game$Card$allSuits));
				return $elm$core$Set$fromList(
					_Utils_ap(predShapes, succShapes));
			}
		}
	} else {
		return $elm$core$Set$empty;
	}
};
var $elm$core$Dict$filter = F2(
	function (isGood, dict) {
		return A3(
			$elm$core$Dict$foldl,
			F3(
				function (k, v, d) {
					return A2(isGood, k, v) ? A3($elm$core$Dict$insert, k, v, d) : d;
				}),
			$elm$core$Dict$empty,
			dict);
	});
var $elm$core$Dict$member = F2(
	function (key, dict) {
		var _v0 = A2($elm$core$Dict$get, key, dict);
		if (_v0.$ === 'Just') {
			return true;
		} else {
			return false;
		}
	});
var $elm$core$Dict$intersect = F2(
	function (t1, t2) {
		return A2(
			$elm$core$Dict$filter,
			F2(
				function (k, _v0) {
					return A2($elm$core$Dict$member, k, t2);
				}),
			t1);
	});
var $elm$core$Set$intersect = F2(
	function (_v0, _v1) {
		var dict1 = _v0.a;
		var dict2 = _v1.a;
		return $elm$core$Set$Set_elm_builtin(
			A2($elm$core$Dict$intersect, dict1, dict2));
	});
var $elm$core$Dict$isEmpty = function (dict) {
	if (dict.$ === 'RBEmpty_elm_builtin') {
		return true;
	} else {
		return false;
	}
};
var $elm$core$Set$isEmpty = function (_v0) {
	var dict = _v0.a;
	return $elm$core$Dict$isEmpty(dict);
};
var $author$project$Game$Agent$Enumerator$hasDoomedThird = F2(
	function (partial, inventory) {
		return $elm$core$Set$isEmpty(
			A2(
				$elm$core$Set$intersect,
				inventory,
				$author$project$Game$Agent$Enumerator$completionShapes(partial)));
	});
var $author$project$Game$Agent$Cards$isPairOk = F2(
	function (a, b) {
		var sameValue = _Utils_eq(a.value, b.value);
		var sameSuit = _Utils_eq(a.suit, b.suit);
		var consecutive = _Utils_eq(
			$author$project$Game$StackType$successor(a.value),
			b.value);
		return (sameValue && (!sameSuit)) ? true : ((consecutive && sameSuit) ? true : ((consecutive && (!_Utils_eq(
			$author$project$Game$Card$cardColor(a),
			$author$project$Game$Card$cardColor(b)))) ? true : false));
	});
var $author$project$Game$Agent$Cards$isPartialOk = function (stack) {
	if (!stack.b) {
		return true;
	} else {
		if (!stack.b.b) {
			return true;
		} else {
			if (!stack.b.b.b) {
				var a = stack.a;
				var _v1 = stack.b;
				var b = _v1.a;
				return A2($author$project$Game$Agent$Cards$isPairOk, a, b);
			} else {
				return $author$project$Game$Agent$Cards$isLegalStack(stack);
			}
		}
	}
};
var $author$project$Game$Agent$Enumerator$admissiblePartial = F2(
	function (merged, inventory) {
		return (!$author$project$Game$Agent$Cards$isPartialOk(merged)) ? false : ((($elm$core$List$length(merged) === 2) && A2($author$project$Game$Agent$Enumerator$hasDoomedThird, merged, inventory)) ? false : true);
	});
var $author$project$Game$Agent$Enumerator$graduate = F3(
	function (merged, growing, complete) {
		return $author$project$Game$Agent$Cards$isLegalStack(merged) ? _Utils_Tuple3(
			growing,
			_Utils_ap(
				complete,
				_List_fromArray(
					[merged])),
			true) : _Utils_Tuple3(
			_Utils_ap(
				growing,
				_List_fromArray(
					[merged])),
			complete,
			false);
	});
var $author$project$Game$Agent$Enumerator$removeAbsorber = F4(
	function (bucket, idx, trouble, growing) {
		if (bucket.$ === 'Trouble') {
			return _Utils_Tuple2(
				A2($author$project$Game$Agent$Enumerator$dropAt, idx, trouble),
				growing);
		} else {
			return _Utils_Tuple2(
				trouble,
				A2($author$project$Game$Agent$Enumerator$dropAt, idx, growing));
		}
	});
var $author$project$Game$Agent$Enumerator$emitFreePull = F5(
	function (state, inventory, absorber, li, loose) {
		return A2(
			$elm$core$List$filterMap,
			function (side) {
				var merged = function () {
					if (side.$ === 'RightSide') {
						return _Utils_ap(
							absorber.target,
							_List_fromArray(
								[loose]));
					} else {
						return A2($elm$core$List$cons, loose, absorber.target);
					}
				}();
				if (!A2($author$project$Game$Agent$Enumerator$admissiblePartial, merged, inventory)) {
					return $elm$core$Maybe$Nothing;
				} else {
					var _v0 = A4($author$project$Game$Agent$Enumerator$removeAbsorber, absorber.bucket, absorber.idx, state.trouble, state.growing);
					var ntBase = _v0.a;
					var ng = _v0.b;
					var nt = function () {
						var _v2 = absorber.bucket;
						if (_v2.$ === 'Trouble') {
							var liInBase = (_Utils_cmp(li, absorber.idx) > 0) ? (li - 1) : li;
							return A2($author$project$Game$Agent$Enumerator$dropAt, liInBase, ntBase);
						} else {
							return A2($author$project$Game$Agent$Enumerator$dropAt, li, ntBase);
						}
					}();
					var _v1 = A3($author$project$Game$Agent$Enumerator$graduate, merged, ng, state.complete);
					var ngFinal = _v1.a;
					var nc = _v1.b;
					var graduated = _v1.c;
					var desc = {graduated: graduated, loose: loose, result: merged, side: side, targetBefore: absorber.target, targetBucketBefore: absorber.bucket};
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(
							$author$project$Game$Agent$Move$FreePull(desc),
							{complete: nc, growing: ngFinal, helper: state.helper, trouble: nt}));
				}
			},
			_List_fromArray(
				[$author$project$Game$Agent$Move$RightSide, $author$project$Game$Agent$Move$LeftSide]));
	});
var $elm$core$List$member = F2(
	function (x, xs) {
		return A2(
			$elm$core$List$any,
			function (a) {
				return _Utils_eq(a, x);
			},
			xs);
	});
var $author$project$Game$Agent$Enumerator$freePullMoves = F4(
	function (state, inventory, absorber, shapes) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var li = _v0.a;
				var looseStack = _v0.b;
				if ($elm$core$List$length(looseStack) !== 1) {
					return _List_Nil;
				} else {
					if (_Utils_eq(absorber.bucket, $author$project$Game$Agent$Move$Trouble) && _Utils_eq(li, absorber.idx)) {
						return _List_Nil;
					} else {
						var _v1 = $elm$core$List$head(looseStack);
						if (_v1.$ === 'Nothing') {
							return _List_Nil;
						} else {
							var loose = _v1.a;
							return (!A2(
								$elm$core$List$member,
								$author$project$Game$Agent$Enumerator$shapeOfCard(loose),
								shapes)) ? _List_Nil : A5($author$project$Game$Agent$Enumerator$emitFreePull, state, inventory, absorber, li, loose);
						}
					}
				}
			},
			A2(
				$elm$core$List$indexedMap,
				F2(
					function (li, ts) {
						return _Utils_Tuple2(li, ts);
					}),
				state.trouble));
	});
var $author$project$Game$Agent$Move$ExtractAbsorb = function (a) {
	return {$: 'ExtractAbsorb', a: a};
};
var $author$project$Game$Agent$Enumerator$KSet = {$: 'KSet'};
var $author$project$Game$Agent$Enumerator$KOther = {$: 'KOther'};
var $author$project$Game$Agent$Enumerator$KPureRun = {$: 'KPureRun'};
var $author$project$Game$Agent$Enumerator$KRbRun = {$: 'KRbRun'};
var $author$project$Game$Agent$Enumerator$classify = function (stack) {
	var _v0 = $author$project$Game$StackType$getStackType(stack);
	switch (_v0.$) {
		case 'Set':
			return $author$project$Game$Agent$Enumerator$KSet;
		case 'PureRun':
			return $author$project$Game$Agent$Enumerator$KPureRun;
		case 'RedBlackRun':
			return $author$project$Game$Agent$Enumerator$KRbRun;
		default:
			return $author$project$Game$Agent$Enumerator$KOther;
	}
};
var $elm$core$List$singleton = function (value) {
	return _List_fromArray(
		[value]);
};
var $elm$core$Basics$ge = _Utils_ge;
var $author$project$Game$Agent$Enumerator$yankShape = F2(
	function (source, ci) {
		var halves = _List_fromArray(
			[
				A2($elm$core$List$take, ci, source),
				A2($elm$core$List$drop, ci + 1, source)
			]);
		return _Utils_Tuple2(
			A2(
				$elm$core$List$filter,
				function (s) {
					return $elm$core$List$length(s) >= 3;
				},
				halves),
			A2(
				$elm$core$List$filter,
				function (s) {
					return $elm$core$List$length(s) < 3;
				},
				halves));
	});
var $author$project$Game$Agent$Enumerator$extractPieces = F3(
	function (source, ci, verb) {
		switch (verb.$) {
			case 'Peel':
				var kind = $author$project$Game$Agent$Enumerator$classify(source);
				var remnant = function () {
					if (_Utils_eq(kind, $author$project$Game$Agent$Enumerator$KSet)) {
						var _v1 = $elm$core$List$head(
							A2($elm$core$List$drop, ci, source));
						if (_v1.$ === 'Just') {
							var c = _v1.a;
							return A2(
								$elm$core$List$filter,
								function (x) {
									return !_Utils_eq(x, c);
								},
								source);
						} else {
							return source;
						}
					} else {
						if (!ci) {
							return A2($elm$core$List$drop, 1, source);
						} else {
							return A2(
								$elm$core$List$take,
								$elm$core$List$length(source) - 1,
								source);
						}
					}
				}();
				return _Utils_Tuple2(
					_List_fromArray(
						[remnant]),
					_List_Nil);
			case 'Pluck':
				return _Utils_Tuple2(
					_List_fromArray(
						[
							A2($elm$core$List$take, ci, source),
							A2($elm$core$List$drop, ci + 1, source)
						]),
					_List_Nil);
			case 'Yank':
				return A2($author$project$Game$Agent$Enumerator$yankShape, source, ci);
			case 'SplitOut':
				return A2($author$project$Game$Agent$Enumerator$yankShape, source, ci);
			default:
				var kind = $author$project$Game$Agent$Enumerator$classify(source);
				if (kind.$ === 'KSet') {
					var _v3 = $elm$core$List$head(
						A2($elm$core$List$drop, ci, source));
					if (_v3.$ === 'Just') {
						var c = _v3.a;
						return _Utils_Tuple2(
							_List_Nil,
							A2(
								$elm$core$List$map,
								$elm$core$List$singleton,
								A2(
									$elm$core$List$filter,
									$elm$core$Basics$neq(c),
									source)));
					} else {
						return _Utils_Tuple2(_List_Nil, _List_Nil);
					}
				} else {
					var remnant = (!ci) ? A2($elm$core$List$drop, 1, source) : A2(
						$elm$core$List$take,
						$elm$core$List$length(source) - 1,
						source);
					return _Utils_Tuple2(
						_List_Nil,
						_List_fromArray(
							[remnant]));
				}
		}
	});
var $author$project$Game$Agent$Enumerator$emitExtractAbsorb = F8(
	function (state, inventory, absorber, hi, src, ci, extCard, verb) {
		var _v0 = A3($author$project$Game$Agent$Enumerator$extractPieces, src, ci, verb);
		var helperPieces = _v0.a;
		var spawned = _v0.b;
		var newHelper = _Utils_ap(
			A2($author$project$Game$Agent$Enumerator$dropAt, hi, state.helper),
			helperPieces);
		return A2(
			$elm$core$List$filterMap,
			function (side) {
				var merged = function () {
					if (side.$ === 'RightSide') {
						return _Utils_ap(
							absorber.target,
							_List_fromArray(
								[extCard]));
					} else {
						return A2($elm$core$List$cons, extCard, absorber.target);
					}
				}();
				if (!A2($author$project$Game$Agent$Enumerator$admissiblePartial, merged, inventory)) {
					return $elm$core$Maybe$Nothing;
				} else {
					var _v1 = A4($author$project$Game$Agent$Enumerator$removeAbsorber, absorber.bucket, absorber.idx, state.trouble, state.growing);
					var ntBase = _v1.a;
					var ng = _v1.b;
					var nt = _Utils_ap(ntBase, spawned);
					var _v2 = A3($author$project$Game$Agent$Enumerator$graduate, merged, ng, state.complete);
					var ngFinal = _v2.a;
					var nc = _v2.b;
					var graduated = _v2.c;
					var desc = {extCard: extCard, graduated: graduated, result: merged, side: side, source: src, spawned: spawned, targetBefore: absorber.target, targetBucketBefore: absorber.bucket, verb: verb};
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(
							$author$project$Game$Agent$Move$ExtractAbsorb(desc),
							{complete: nc, growing: ngFinal, helper: newHelper, trouble: nt}));
				}
			},
			_List_fromArray(
				[$author$project$Game$Agent$Move$RightSide, $author$project$Game$Agent$Move$LeftSide]));
	});
var $elm$core$Maybe$andThen = F2(
	function (callback, maybeValue) {
		if (maybeValue.$ === 'Just') {
			var value = maybeValue.a;
			return callback(value);
		} else {
			return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$Agent$Enumerator$lookupHelperCard = F3(
	function (helper, hi, ci) {
		return A2(
			$elm$core$Maybe$andThen,
			function (src) {
				return A2(
					$elm$core$Maybe$map,
					function (c) {
						return _Utils_Tuple2(src, c);
					},
					$elm$core$List$head(
						A2($elm$core$List$drop, ci, src)));
			},
			$elm$core$List$head(
				A2($elm$core$List$drop, hi, helper)));
	});
var $author$project$Game$Agent$Enumerator$helperExtractMoves = F5(
	function (state, inventory, extractable, absorber, shapes) {
		return A2(
			$elm$core$List$concatMap,
			function (shape) {
				return A2(
					$elm$core$List$concatMap,
					function (entry) {
						var _v0 = A3($author$project$Game$Agent$Enumerator$lookupHelperCard, state.helper, entry.hi, entry.ci);
						if (_v0.$ === 'Just') {
							var _v1 = _v0.a;
							var src = _v1.a;
							var extCard = _v1.b;
							return A8($author$project$Game$Agent$Enumerator$emitExtractAbsorb, state, inventory, absorber, entry.hi, src, entry.ci, extCard, entry.verb);
						} else {
							return _List_Nil;
						}
					},
					A2(
						$elm$core$Maybe$withDefault,
						_List_Nil,
						A2($elm$core$Dict$get, shape, extractable)));
			},
			shapes);
	});
var $author$project$Game$StackType$predecessor = function (v) {
	switch (v.$) {
		case 'Ace':
			return $author$project$Game$Card$King;
		case 'Two':
			return $author$project$Game$Card$Ace;
		case 'Three':
			return $author$project$Game$Card$Two;
		case 'Four':
			return $author$project$Game$Card$Three;
		case 'Five':
			return $author$project$Game$Card$Four;
		case 'Six':
			return $author$project$Game$Card$Five;
		case 'Seven':
			return $author$project$Game$Card$Six;
		case 'Eight':
			return $author$project$Game$Card$Seven;
		case 'Nine':
			return $author$project$Game$Card$Eight;
		case 'Ten':
			return $author$project$Game$Card$Nine;
		case 'Jack':
			return $author$project$Game$Card$Ten;
		case 'Queen':
			return $author$project$Game$Card$Jack;
		default:
			return $author$project$Game$Card$Queen;
	}
};
var $author$project$Game$Agent$Cards$neighbors = function (c) {
	var succ = $author$project$Game$StackType$successor(c.value);
	var sameValueOtherSuits = A2(
		$elm$core$List$filter,
		function (s) {
			return !_Utils_eq(s, c.suit);
		},
		$author$project$Game$Card$allSuits);
	var setPartners = A2(
		$elm$core$List$map,
		function (s) {
			return _Utils_Tuple2(c.value, s);
		},
		sameValueOtherSuits);
	var pred = $author$project$Game$StackType$predecessor(c.value);
	var pureRunPartners = _List_fromArray(
		[
			_Utils_Tuple2(pred, c.suit),
			_Utils_Tuple2(succ, c.suit)
		]);
	var cColor = $author$project$Game$Card$cardColor(c);
	var oppositeColorSuits = A2(
		$elm$core$List$filter,
		function (s) {
			return !_Utils_eq(
				$author$project$Game$Card$suitColor(s),
				cColor);
		},
		$author$project$Game$Card$allSuits);
	var rbRunPartners = A2(
		$elm$core$List$concatMap,
		function (s) {
			return _List_fromArray(
				[
					_Utils_Tuple2(pred, s),
					_Utils_Tuple2(succ, s)
				]);
		},
		oppositeColorSuits);
	return _Utils_ap(
		pureRunPartners,
		_Utils_ap(rbRunPartners, setPartners));
};
var $author$project$Game$Agent$Enumerator$neighborShapes = function (target) {
	return $elm$core$Set$toList(
		$elm$core$Set$fromList(
			A2(
				$elm$core$List$map,
				function (_v0) {
					var v = _v0.a;
					var s = _v0.b;
					return _Utils_Tuple2(
						$author$project$Game$Card$cardValueToInt(v),
						$author$project$Game$Card$suitToInt(s));
				},
				A2($elm$core$List$concatMap, $author$project$Game$Agent$Cards$neighbors, target))));
};
var $author$project$Game$Agent$Enumerator$absorberMoves = F4(
	function (state, inventory, extractable, absorber) {
		var shapes = $author$project$Game$Agent$Enumerator$neighborShapes(absorber.target);
		return _Utils_ap(
			A5($author$project$Game$Agent$Enumerator$helperExtractMoves, state, inventory, extractable, absorber, shapes),
			A4($author$project$Game$Agent$Enumerator$freePullMoves, state, inventory, absorber, shapes));
	});
var $author$project$Game$Agent$Move$Growing = {$: 'Growing'};
var $author$project$Game$Agent$Enumerator$absorbersOf = function (_v0) {
	var trouble = _v0.trouble;
	var growing = _v0.growing;
	var ts = A2(
		$elm$core$List$indexedMap,
		F2(
			function (i, t) {
				return {bucket: $author$project$Game$Agent$Move$Trouble, idx: i, target: t};
			}),
		trouble);
	var gs = A2(
		$elm$core$List$indexedMap,
		F2(
			function (i, g) {
				return {bucket: $author$project$Game$Agent$Move$Growing, idx: i, target: g};
			}),
		growing);
	return _Utils_ap(ts, gs);
};
var $author$project$Game$Agent$Enumerator$extractAndAbsorbMoves = F3(
	function (state, inventory, extractable) {
		return A2(
			$elm$core$List$concatMap,
			function (a) {
				return A4($author$project$Game$Agent$Enumerator$absorberMoves, state, inventory, extractable, a);
			},
			$author$project$Game$Agent$Enumerator$absorbersOf(state));
	});
var $elm$core$Tuple$pair = F2(
	function (a, b) {
		return _Utils_Tuple2(a, b);
	});
var $author$project$Game$Agent$Move$Peel = {$: 'Peel'};
var $author$project$Game$Agent$Move$Pluck = {$: 'Pluck'};
var $author$project$Game$Agent$Move$SplitOut = {$: 'SplitOut'};
var $author$project$Game$Agent$Move$Steal = {$: 'Steal'};
var $author$project$Game$Agent$Move$Yank = {$: 'Yank'};
var $author$project$Game$Agent$Enumerator$canPeel = F3(
	function (kind, n, ci) {
		switch (kind.$) {
			case 'KSet':
				return n >= 4;
			case 'KPureRun':
				return (n >= 4) && ((!ci) || _Utils_eq(ci, n - 1));
			case 'KRbRun':
				return (n >= 4) && ((!ci) || _Utils_eq(ci, n - 1));
			default:
				return false;
		}
	});
var $author$project$Game$Agent$Enumerator$isRunKind = function (kind) {
	switch (kind.$) {
		case 'KPureRun':
			return true;
		case 'KRbRun':
			return true;
		default:
			return false;
	}
};
var $author$project$Game$Agent$Enumerator$canPluck = F3(
	function (kind, n, ci) {
		return $author$project$Game$Agent$Enumerator$isRunKind(kind) && ((ci >= 3) && (_Utils_cmp(ci, n - 4) < 1));
	});
var $author$project$Game$Agent$Enumerator$canSplitOut = F3(
	function (kind, n, ci) {
		return $author$project$Game$Agent$Enumerator$isRunKind(kind) && ((n === 3) && (ci === 1));
	});
var $author$project$Game$Agent$Enumerator$canSteal = F3(
	function (kind, n, ci) {
		if (n !== 3) {
			return false;
		} else {
			switch (kind.$) {
				case 'KPureRun':
					return (!ci) || _Utils_eq(ci, n - 1);
				case 'KRbRun':
					return (!ci) || _Utils_eq(ci, n - 1);
				case 'KSet':
					return true;
				default:
					return false;
			}
		}
	});
var $elm$core$Basics$min = F2(
	function (x, y) {
		return (_Utils_cmp(x, y) < 0) ? x : y;
	});
var $author$project$Game$Agent$Enumerator$canYank = F3(
	function (kind, n, ci) {
		if (!$author$project$Game$Agent$Enumerator$isRunKind(kind)) {
			return false;
		} else {
			if ((!ci) || (_Utils_eq(ci, n - 1) || ((ci >= 3) && (_Utils_cmp(ci, n - 4) < 1)))) {
				return false;
			} else {
				var rightLen = (n - ci) - 1;
				var leftLen = ci;
				return (A2($elm$core$Basics$max, leftLen, rightLen) >= 3) && (A2($elm$core$Basics$min, leftLen, rightLen) >= 1);
			}
		}
	});
var $author$project$Game$Agent$Enumerator$verbFor = F3(
	function (kind, n, ci) {
		return A3($author$project$Game$Agent$Enumerator$canPeel, kind, n, ci) ? $elm$core$Maybe$Just($author$project$Game$Agent$Move$Peel) : (A3($author$project$Game$Agent$Enumerator$canPluck, kind, n, ci) ? $elm$core$Maybe$Just($author$project$Game$Agent$Move$Pluck) : (A3($author$project$Game$Agent$Enumerator$canYank, kind, n, ci) ? $elm$core$Maybe$Just($author$project$Game$Agent$Move$Yank) : (A3($author$project$Game$Agent$Enumerator$canSteal, kind, n, ci) ? $elm$core$Maybe$Just($author$project$Game$Agent$Move$Steal) : (A3($author$project$Game$Agent$Enumerator$canSplitOut, kind, n, ci) ? $elm$core$Maybe$Just($author$project$Game$Agent$Move$SplitOut) : $elm$core$Maybe$Nothing))));
	});
var $author$project$Game$Agent$Enumerator$addHelperEntries = F2(
	function (_v0, acc) {
		var hi = _v0.a;
		var src = _v0.b;
		var n = $elm$core$List$length(src);
		var kind = $author$project$Game$Agent$Enumerator$classify(src);
		return A3(
			$elm$core$List$foldl,
			F2(
				function (_v1, inner) {
					var ci = _v1.a;
					var c = _v1.b;
					var _v2 = A3($author$project$Game$Agent$Enumerator$verbFor, kind, n, ci);
					if (_v2.$ === 'Nothing') {
						return inner;
					} else {
						var verb = _v2.a;
						var key = _Utils_Tuple2(
							$author$project$Game$Card$cardValueToInt(c.value),
							$author$project$Game$Card$suitToInt(c.suit));
						var entry = {ci: ci, hi: hi, verb: verb};
						return A3(
							$elm$core$Dict$update,
							key,
							function (maybeList) {
								if (maybeList.$ === 'Just') {
									var xs = maybeList.a;
									return $elm$core$Maybe$Just(
										_Utils_ap(
											xs,
											_List_fromArray(
												[entry])));
								} else {
									return $elm$core$Maybe$Just(
										_List_fromArray(
											[entry]));
								}
							},
							inner);
					}
				}),
			acc,
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, src));
	});
var $author$project$Game$Agent$Enumerator$extractableIndex = function (helper) {
	return A3(
		$elm$core$List$foldl,
		$author$project$Game$Agent$Enumerator$addHelperEntries,
		$elm$core$Dict$empty,
		A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, helper));
};
var $author$project$Game$Agent$Enumerator$pushOnto = F4(
	function (state, ti, t, helper) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var hi = _v0.a;
				var h = _v0.b;
				return A2(
					$elm$core$List$filterMap,
					function (side) {
						var merged = function () {
							if (side.$ === 'RightSide') {
								return _Utils_ap(h, t);
							} else {
								return _Utils_ap(t, h);
							}
						}();
						if (!$author$project$Game$Agent$Cards$isLegalStack(merged)) {
							return $elm$core$Maybe$Nothing;
						} else {
							var newState = {
								complete: state.complete,
								growing: state.growing,
								helper: _Utils_ap(
									A2($author$project$Game$Agent$Enumerator$dropAt, hi, state.helper),
									_List_fromArray(
										[merged])),
								trouble: A2($author$project$Game$Agent$Enumerator$dropAt, ti, state.trouble)
							};
							var desc = {result: merged, side: side, targetBefore: h, troubleBefore: t};
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(
									$author$project$Game$Agent$Move$Push(desc),
									newState));
						}
					},
					_List_fromArray(
						[$author$project$Game$Agent$Move$RightSide, $author$project$Game$Agent$Move$LeftSide]));
			},
			A2(
				$elm$core$List$indexedMap,
				F2(
					function (hi, h) {
						return _Utils_Tuple2(hi, h);
					}),
				helper));
	});
var $author$project$Game$Agent$Enumerator$pushMoves = function (state) {
	return A2(
		$elm$core$List$concatMap,
		function (_v0) {
			var ti = _v0.a;
			var t = _v0.b;
			return ($elm$core$List$length(t) > 2) ? _List_Nil : A4($author$project$Game$Agent$Enumerator$pushOnto, state, ti, t, state.helper);
		},
		A2(
			$elm$core$List$indexedMap,
			F2(
				function (ti, t) {
					return _Utils_Tuple2(ti, t);
				}),
			state.trouble));
};
var $author$project$Game$Agent$Move$LeftEnd = {$: 'LeftEnd'};
var $author$project$Game$Agent$Move$RightEnd = {$: 'RightEnd'};
var $author$project$Game$Agent$Enumerator$cardAt = F2(
	function (stack, i) {
		return $elm$core$List$head(
			A2($elm$core$List$drop, i, stack));
	});
var $author$project$Game$Agent$Move$Shift = function (a) {
	return {$: 'Shift', a: a};
};
var $author$project$Game$Agent$Enumerator$shiftEmit = function (state) {
	return function (inventory) {
		return function (absorber) {
			return function (srcIdx) {
				return function (source) {
					return function (kind) {
						return function (whichEnd) {
							return function (stolen) {
								return function (pCard) {
									return function (donorIdx) {
										return function (newDonor) {
											var newSource = function () {
												var _v4 = _Utils_Tuple2(whichEnd, source);
												_v4$2:
												while (true) {
													if (_v4.a.$ === 'RightEnd') {
														if (((_v4.b.b && _v4.b.b.b) && _v4.b.b.b.b) && (!_v4.b.b.b.b.b)) {
															var _v5 = _v4.a;
															var _v6 = _v4.b;
															var a = _v6.a;
															var _v7 = _v6.b;
															var b = _v7.a;
															var _v8 = _v7.b;
															return _List_fromArray(
																[pCard, a, b]);
														} else {
															break _v4$2;
														}
													} else {
														if (((_v4.b.b && _v4.b.b.b) && _v4.b.b.b.b) && (!_v4.b.b.b.b.b)) {
															var _v9 = _v4.a;
															var _v10 = _v4.b;
															var _v11 = _v10.b;
															var b = _v11.a;
															var _v12 = _v11.b;
															var c = _v12.a;
															return _List_fromArray(
																[b, c, pCard]);
														} else {
															break _v4$2;
														}
													}
												}
												return source;
											}();
											var sameKind = _Utils_eq(
												$author$project$Game$Agent$Enumerator$classify(newSource),
												kind);
											return (!sameKind) ? _List_Nil : A2(
												$elm$core$List$filterMap,
												function (side) {
													var merged = function () {
														if (side.$ === 'RightSide') {
															return _Utils_ap(
																absorber.target,
																_List_fromArray(
																	[stolen]));
														} else {
															return A2($elm$core$List$cons, stolen, absorber.target);
														}
													}();
													if (!A2($author$project$Game$Agent$Enumerator$admissiblePartial, merged, inventory)) {
														return $elm$core$Maybe$Nothing;
													} else {
														var donorStack = A2(
															$elm$core$Maybe$withDefault,
															_List_Nil,
															$elm$core$List$head(
																A2($elm$core$List$drop, donorIdx, state.helper)));
														var _v0 = A4($author$project$Game$Agent$Enumerator$removeAbsorber, absorber.bucket, absorber.idx, state.trouble, state.growing);
														var ntBase = _v0.a;
														var ng = _v0.b;
														var _v1 = (_Utils_cmp(srcIdx, donorIdx) > 0) ? _Utils_Tuple2(srcIdx, donorIdx) : _Utils_Tuple2(donorIdx, srcIdx);
														var hi = _v1.a;
														var lo = _v1.b;
														var helperWithoutPair = A2(
															$author$project$Game$Agent$Enumerator$dropAt,
															lo,
															A2($author$project$Game$Agent$Enumerator$dropAt, hi, state.helper));
														var newHelper = _Utils_ap(
															helperWithoutPair,
															_List_fromArray(
																[newSource, newDonor]));
														var _v2 = A3($author$project$Game$Agent$Enumerator$graduate, merged, ng, state.complete);
														var ngFinal = _v2.a;
														var nc = _v2.b;
														var graduated = _v2.c;
														var desc = {donor: donorStack, graduated: graduated, merged: merged, newDonor: newDonor, newSource: newSource, pCard: pCard, side: side, source: source, stolen: stolen, targetBefore: absorber.target, targetBucketBefore: absorber.bucket, whichEnd: whichEnd};
														return $elm$core$Maybe$Just(
															_Utils_Tuple2(
																$author$project$Game$Agent$Move$Shift(desc),
																{complete: nc, growing: ngFinal, helper: newHelper, trouble: ntBase}));
													}
												},
												_List_fromArray(
													[$author$project$Game$Agent$Move$RightSide, $author$project$Game$Agent$Move$LeftSide]));
										};
									};
								};
							};
						};
					};
				};
			};
		};
	};
};
var $author$project$Game$Agent$Enumerator$shiftEmitFromEntry = F9(
	function (state, inventory, absorber, srcIdx, source, kind, whichEnd, stolen, entry) {
		var _v0 = A3($author$project$Game$Agent$Enumerator$lookupHelperCard, state.helper, entry.hi, entry.ci);
		if (_v0.$ === 'Just') {
			var _v1 = _v0.a;
			var donor = _v1.a;
			var pCard = _v1.b;
			var _v2 = A3($author$project$Game$Agent$Enumerator$extractPieces, donor, entry.ci, $author$project$Game$Agent$Move$Peel);
			var helperPieces = _v2.a;
			if (helperPieces.b && (!helperPieces.b.b)) {
				var newDonor = helperPieces.a;
				return $author$project$Game$Agent$Enumerator$shiftEmit(state)(inventory)(absorber)(srcIdx)(source)(kind)(whichEnd)(stolen)(pCard)(entry.hi)(newDonor);
			} else {
				return _List_Nil;
			}
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Enumerator$shiftFromEnd = F9(
	function (state, inventory, extractable, absorber, shapes, srcIdx, source, kind, whichEnd) {
		var stolenIdx = function () {
			if (whichEnd.$ === 'LeftEnd') {
				return 0;
			} else {
				return 2;
			}
		}();
		var anchorIdx = function () {
			if (whichEnd.$ === 'LeftEnd') {
				return 2;
			} else {
				return 0;
			}
		}();
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Agent$Enumerator$cardAt, source, stolenIdx),
			A2($author$project$Game$Agent$Enumerator$cardAt, source, anchorIdx));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var stolen = _v0.a.a;
			var anchor = _v0.b.a;
			if (!A2(
				$elm$core$List$member,
				$author$project$Game$Agent$Enumerator$shapeOfCard(stolen),
				shapes)) {
				return _List_Nil;
			} else {
				var pValue = function () {
					if (whichEnd.$ === 'RightEnd') {
						return $author$project$Game$StackType$predecessor(anchor.value);
					} else {
						return $author$project$Game$StackType$successor(anchor.value);
					}
				}();
				var neededSuits = function () {
					if (kind.$ === 'KPureRun') {
						return _List_fromArray(
							[anchor.suit]);
					} else {
						return A2(
							$elm$core$List$filter,
							function (s) {
								return !_Utils_eq(
									$author$project$Game$Card$suitColor(s),
									$author$project$Game$Card$cardColor(anchor));
							},
							$author$project$Game$Card$allSuits);
					}
				}();
				return A2(
					$elm$core$List$concatMap,
					function (pSuit) {
						var key = _Utils_Tuple2(
							$author$project$Game$Card$cardValueToInt(pValue),
							$author$project$Game$Card$suitToInt(pSuit));
						return A2(
							$elm$core$List$concatMap,
							function (entry) {
								return (!_Utils_eq(entry.verb, $author$project$Game$Agent$Move$Peel)) ? _List_Nil : (_Utils_eq(entry.hi, srcIdx) ? _List_Nil : A9($author$project$Game$Agent$Enumerator$shiftEmitFromEntry, state, inventory, absorber, srcIdx, source, kind, whichEnd, stolen, entry));
							},
							A2(
								$elm$core$Maybe$withDefault,
								_List_Nil,
								A2($elm$core$Dict$get, key, extractable)));
					},
					neededSuits);
			}
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Enumerator$shiftFromRun = F8(
	function (state, inventory, extractable, absorber, shapes, srcIdx, source, kind) {
		return A2(
			$elm$core$List$concatMap,
			function (whichEnd) {
				return A9($author$project$Game$Agent$Enumerator$shiftFromEnd, state, inventory, extractable, absorber, shapes, srcIdx, source, kind, whichEnd);
			},
			_List_fromArray(
				[$author$project$Game$Agent$Move$LeftEnd, $author$project$Game$Agent$Move$RightEnd]));
	});
var $author$project$Game$Agent$Enumerator$shiftMovesForAbsorber = F4(
	function (state, inventory, extractable, absorber) {
		var shapes = $author$project$Game$Agent$Enumerator$neighborShapes(absorber.target);
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var srcIdx = _v0.a;
				var source = _v0.b;
				if ($elm$core$List$length(source) !== 3) {
					return _List_Nil;
				} else {
					var _v1 = $author$project$Game$Agent$Enumerator$classify(source);
					switch (_v1.$) {
						case 'KPureRun':
							return A8($author$project$Game$Agent$Enumerator$shiftFromRun, state, inventory, extractable, absorber, shapes, srcIdx, source, $author$project$Game$Agent$Enumerator$KPureRun);
						case 'KRbRun':
							return A8($author$project$Game$Agent$Enumerator$shiftFromRun, state, inventory, extractable, absorber, shapes, srcIdx, source, $author$project$Game$Agent$Enumerator$KRbRun);
						default:
							return _List_Nil;
					}
				}
			},
			A2(
				$elm$core$List$indexedMap,
				F2(
					function (srcIdx, src) {
						return _Utils_Tuple2(srcIdx, src);
					}),
				state.helper));
	});
var $author$project$Game$Agent$Enumerator$shiftMoves = F3(
	function (state, inventory, extractable) {
		return A2(
			$elm$core$List$concatMap,
			function (absorber) {
				return A4($author$project$Game$Agent$Enumerator$shiftMovesForAbsorber, state, inventory, extractable, absorber);
			},
			$author$project$Game$Agent$Enumerator$absorbersOf(state));
	});
var $author$project$Game$Agent$Move$Splice = function (a) {
	return {$: 'Splice', a: a};
};
var $author$project$Game$Agent$Enumerator$spliceCandidates = F6(
	function (state, ti, loose, hi, src, n) {
		return A2(
			$elm$core$List$concatMap,
			function (k) {
				var spliceForJoin = F2(
					function (side, _v0) {
						var left = _v0.a;
						var right = _v0.b;
						if (($elm$core$List$length(left) >= 3) && (($elm$core$List$length(right) >= 3) && ($author$project$Game$Agent$Cards$isLegalStack(left) && $author$project$Game$Agent$Cards$isLegalStack(right)))) {
							var newState = {
								complete: state.complete,
								growing: state.growing,
								helper: _Utils_ap(
									A2($author$project$Game$Agent$Enumerator$dropAt, hi, state.helper),
									_List_fromArray(
										[left, right])),
								trouble: A2($author$project$Game$Agent$Enumerator$dropAt, ti, state.trouble)
							};
							var desc = {k: k, leftResult: left, loose: loose, rightResult: right, side: side, source: src};
							return _List_fromArray(
								[
									_Utils_Tuple2(
									$author$project$Game$Agent$Move$Splice(desc),
									newState)
								]);
						} else {
							return _List_Nil;
						}
					});
				var rightJoin = _Utils_Tuple2(
					A2($elm$core$List$take, k, src),
					A2(
						$elm$core$List$cons,
						loose,
						A2($elm$core$List$drop, k, src)));
				var leftJoin = _Utils_Tuple2(
					_Utils_ap(
						A2($elm$core$List$take, k, src),
						_List_fromArray(
							[loose])),
					A2($elm$core$List$drop, k, src));
				return _Utils_ap(
					A2(spliceForJoin, $author$project$Game$Agent$Move$LeftSide, leftJoin),
					A2(spliceForJoin, $author$project$Game$Agent$Move$RightSide, rightJoin));
			},
			A2($elm$core$List$range, 1, n - 1));
	});
var $author$project$Game$Agent$Enumerator$spliceFromTrouble = F3(
	function (state, ti, loose) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var hi = _v0.a;
				var src = _v0.b;
				var n = $elm$core$List$length(src);
				if (n < 4) {
					return _List_Nil;
				} else {
					var _v1 = $author$project$Game$Agent$Enumerator$classify(src);
					switch (_v1.$) {
						case 'KPureRun':
							return A6($author$project$Game$Agent$Enumerator$spliceCandidates, state, ti, loose, hi, src, n);
						case 'KRbRun':
							return A6($author$project$Game$Agent$Enumerator$spliceCandidates, state, ti, loose, hi, src, n);
						default:
							return _List_Nil;
					}
				}
			},
			A2(
				$elm$core$List$indexedMap,
				F2(
					function (hi, src) {
						return _Utils_Tuple2(hi, src);
					}),
				state.helper));
	});
var $author$project$Game$Agent$Enumerator$spliceMoves = function (state) {
	return A2(
		$elm$core$List$concatMap,
		function (_v0) {
			var ti = _v0.a;
			var t = _v0.b;
			if (t.b && (!t.b.b)) {
				var loose = t.a;
				return A3($author$project$Game$Agent$Enumerator$spliceFromTrouble, state, ti, loose);
			} else {
				return _List_Nil;
			}
		},
		A2(
			$elm$core$List$indexedMap,
			F2(
				function (ti, t) {
					return _Utils_Tuple2(ti, t);
				}),
			state.trouble));
};
var $author$project$Game$Agent$Enumerator$enumerateMoves = function (state) {
	var inventory = $author$project$Game$Agent$Enumerator$completionInventory(state);
	var hasDoomedGrowing = A2(
		$elm$core$List$any,
		function (g) {
			return ($elm$core$List$length(g) === 2) && A2($author$project$Game$Agent$Enumerator$hasDoomedThird, g, inventory);
		},
		state.growing);
	if (hasDoomedGrowing) {
		return _List_Nil;
	} else {
		var extractable = $author$project$Game$Agent$Enumerator$extractableIndex(state.helper);
		return _Utils_ap(
			A3($author$project$Game$Agent$Enumerator$extractAndAbsorbMoves, state, inventory, extractable),
			_Utils_ap(
				A3($author$project$Game$Agent$Enumerator$shiftMoves, state, inventory, extractable),
				_Utils_ap(
					$author$project$Game$Agent$Enumerator$spliceMoves(state),
					_Utils_ap(
						$author$project$Game$Agent$Enumerator$pushMoves(state),
						$author$project$Game$Agent$Enumerator$engulfMoves(state)))));
	}
};
var $author$project$Game$Agent$Enumerator$moveTouchesFocus = F2(
	function (move, focus) {
		switch (move.$) {
			case 'ExtractAbsorb':
				var d = move.a;
				return _Utils_eq(d.targetBefore, focus);
			case 'Shift':
				var d = move.a;
				return _Utils_eq(d.targetBefore, focus);
			case 'FreePull':
				var d = move.a;
				return _Utils_eq(d.targetBefore, focus) || function () {
					if (focus.b && (!focus.b.b)) {
						var c = focus.a;
						return _Utils_eq(c, d.loose);
					} else {
						return false;
					}
				}();
			case 'Splice':
				var d = move.a;
				if (focus.b && (!focus.b.b)) {
					var c = focus.a;
					return _Utils_eq(c, d.loose);
				} else {
					return false;
				}
			default:
				var d = move.a;
				return _Utils_eq(d.troubleBefore, focus);
		}
	});
var $author$project$Game$Agent$Enumerator$removeFirstEqual = F2(
	function (target, xs) {
		if (!xs.b) {
			return _List_Nil;
		} else {
			var h = xs.a;
			var t = xs.b;
			return _Utils_eq(h, target) ? t : A2(
				$elm$core$List$cons,
				h,
				A2($author$project$Game$Agent$Enumerator$removeFirstEqual, target, t));
		}
	});
var $author$project$Game$Agent$Enumerator$updateMatching = F4(
	function (oldContent, newContent, graduated, xs) {
		if (!xs.b) {
			return _List_Nil;
		} else {
			var h = xs.a;
			var t = xs.b;
			return _Utils_eq(h, oldContent) ? (graduated ? t : A2($elm$core$List$cons, newContent, t)) : A2(
				$elm$core$List$cons,
				h,
				A4($author$project$Game$Agent$Enumerator$updateMatching, oldContent, newContent, graduated, t));
		}
	});
var $author$project$Game$Agent$Enumerator$updateLineage = F2(
	function (lineage, move) {
		if (!lineage.b) {
			return _List_Nil;
		} else {
			var focus = lineage.a;
			var rest = lineage.b;
			switch (move.$) {
				case 'ExtractAbsorb':
					var d = move.a;
					var afterFocus = d.graduated ? rest : A2($elm$core$List$cons, d.result, rest);
					return _Utils_ap(afterFocus, d.spawned);
				case 'Shift':
					var d = move.a;
					return d.graduated ? rest : A2($elm$core$List$cons, d.merged, rest);
				case 'FreePull':
					var d = move.a;
					if (_Utils_eq(d.targetBefore, focus)) {
						var rest2 = A2(
							$author$project$Game$Agent$Enumerator$removeFirstEqual,
							_List_fromArray(
								[d.loose]),
							rest);
						return d.graduated ? rest2 : A2($elm$core$List$cons, d.result, rest2);
					} else {
						return A4($author$project$Game$Agent$Enumerator$updateMatching, d.targetBefore, d.result, d.graduated, rest);
					}
				case 'Splice':
					return rest;
				default:
					return rest;
			}
		}
	});
var $author$project$Game$Agent$Enumerator$enumerateFocused = function (state) {
	var _v0 = state.lineage;
	if (!_v0.b) {
		return _List_Nil;
	} else {
		var focus = _v0.a;
		return A2(
			$elm$core$List$filterMap,
			function (_v1) {
				var move = _v1.a;
				var newBuckets = _v1.b;
				return A2($author$project$Game$Agent$Enumerator$moveTouchesFocus, move, focus) ? $elm$core$Maybe$Just(
					_Utils_Tuple2(
						move,
						{
							buckets: newBuckets,
							lineage: A2($author$project$Game$Agent$Enumerator$updateLineage, state.lineage, move)
						})) : $elm$core$Maybe$Nothing;
			},
			$author$project$Game$Agent$Enumerator$enumerateMoves(state.buckets));
	}
};
var $author$project$Game$Agent$Buckets$isVictory = function (_v0) {
	var trouble = _v0.trouble;
	var growing = _v0.growing;
	return $elm$core$List$isEmpty(trouble) && A2(
		$elm$core$List$all,
		function (s) {
			return $elm$core$List$length(s) >= 3;
		},
		growing);
};
var $elm$core$Set$member = F2(
	function (key, _v0) {
		var dict = _v0.a;
		return A2($elm$core$Dict$member, key, dict);
	});
var $author$project$Game$Card$originDeckToInt = function (d) {
	if (d.$ === 'DeckOne') {
		return 0;
	} else {
		return 1;
	}
};
var $author$project$Game$Agent$Bfs$encodeCard = function (c) {
	return $elm$core$String$fromInt(
		$author$project$Game$Card$cardValueToInt(c.value)) + ('/' + ($elm$core$String$fromInt(
		$author$project$Game$Card$suitToInt(c.suit)) + ('/' + $elm$core$String$fromInt(
		$author$project$Game$Card$originDeckToInt(c.originDeck)))));
};
var $elm$core$List$sort = function (xs) {
	return A2($elm$core$List$sortBy, $elm$core$Basics$identity, xs);
};
var $author$project$Game$Agent$Bfs$encodeStackSorted = function (stack) {
	return A2(
		$elm$core$String$join,
		',',
		$elm$core$List$sort(
			A2($elm$core$List$map, $author$project$Game$Agent$Bfs$encodeCard, stack)));
};
var $author$project$Game$Agent$Bfs$encodeBucket = function (stacks) {
	return A2(
		$elm$core$String$join,
		';',
		$elm$core$List$sort(
			A2($elm$core$List$map, $author$project$Game$Agent$Bfs$encodeStackSorted, stacks)));
};
var $author$project$Game$Agent$Bfs$encodeLineage = function (lineage) {
	return A2(
		$elm$core$String$join,
		';',
		A2($elm$core$List$map, $author$project$Game$Agent$Bfs$encodeStackSorted, lineage));
};
var $author$project$Game$Agent$Bfs$signature = function (_v0) {
	var buckets = _v0.buckets;
	var lineage = _v0.lineage;
	return A2(
		$elm$core$String$join,
		' | ',
		_List_fromArray(
			[
				'H' + $author$project$Game$Agent$Bfs$encodeBucket(buckets.helper),
				'T' + $author$project$Game$Agent$Bfs$encodeBucket(buckets.trouble),
				'G' + $author$project$Game$Agent$Bfs$encodeBucket(buckets.growing),
				'C' + $author$project$Game$Agent$Bfs$encodeBucket(buckets.complete),
				'L' + $author$project$Game$Agent$Bfs$encodeLineage(lineage)
			]));
};
var $author$project$Game$Agent$Bfs$expandMoves = F5(
	function (cap, program, moves, seen, acc) {
		expandMoves:
		while (true) {
			if (!moves.b) {
				return A2($author$project$Game$Agent$Bfs$Continue, acc, seen);
			} else {
				var _v1 = moves.a;
				var move = _v1.a;
				var newState = _v1.b;
				var rest = moves.b;
				if (_Utils_cmp(
					$author$project$Game$Agent$Buckets$troubleCount(newState.buckets),
					cap) > 0) {
					var $temp$cap = cap,
						$temp$program = program,
						$temp$moves = rest,
						$temp$seen = seen,
						$temp$acc = acc;
					cap = $temp$cap;
					program = $temp$program;
					moves = $temp$moves;
					seen = $temp$seen;
					acc = $temp$acc;
					continue expandMoves;
				} else {
					var sig = $author$project$Game$Agent$Bfs$signature(newState);
					if (A2($elm$core$Set$member, sig, seen)) {
						var $temp$cap = cap,
							$temp$program = program,
							$temp$moves = rest,
							$temp$seen = seen,
							$temp$acc = acc;
						cap = $temp$cap;
						program = $temp$program;
						moves = $temp$moves;
						seen = $temp$seen;
						acc = $temp$acc;
						continue expandMoves;
					} else {
						var newSeen = A2($elm$core$Set$insert, sig, seen);
						var newProgram = _Utils_ap(
							program,
							_List_fromArray(
								[move]));
						if ($author$project$Game$Agent$Buckets$isVictory(newState.buckets)) {
							return $author$project$Game$Agent$Bfs$Found(newProgram);
						} else {
							var $temp$cap = cap,
								$temp$program = program,
								$temp$moves = rest,
								$temp$seen = newSeen,
								$temp$acc = A2(
								$elm$core$List$cons,
								_Utils_Tuple2(newState, newProgram),
								acc);
							cap = $temp$cap;
							program = $temp$program;
							moves = $temp$moves;
							seen = $temp$seen;
							acc = $temp$acc;
							continue expandMoves;
						}
					}
				}
			}
		}
	});
var $author$project$Game$Agent$Bfs$expandState = F5(
	function (cap, state, program, seen, acc) {
		var moves = $author$project$Game$Agent$Enumerator$enumerateFocused(state);
		return A5($author$project$Game$Agent$Bfs$expandMoves, cap, program, moves, seen, acc);
	});
var $author$project$Game$Agent$Bfs$walkLevel = F4(
	function (cap, frontier, seen, acc) {
		walkLevel:
		while (true) {
			if (!frontier.b) {
				return A2(
					$author$project$Game$Agent$Bfs$Continue,
					$elm$core$List$reverse(acc),
					seen);
			} else {
				var _v1 = frontier.a;
				var state = _v1.a;
				var program = _v1.b;
				var rest = frontier.b;
				var _v2 = A5($author$project$Game$Agent$Bfs$expandState, cap, state, program, seen, acc);
				if (_v2.$ === 'Found') {
					var plan = _v2.a;
					return $author$project$Game$Agent$Bfs$Found(plan);
				} else {
					var updatedAcc = _v2.a;
					var updatedSeen = _v2.b;
					var $temp$cap = cap,
						$temp$frontier = rest,
						$temp$seen = updatedSeen,
						$temp$acc = updatedAcc;
					cap = $temp$cap;
					frontier = $temp$frontier;
					seen = $temp$seen;
					acc = $temp$acc;
					continue walkLevel;
				}
			}
		}
	});
var $author$project$Game$Agent$Bfs$bfsStep = F3(
	function (cap, currentLevel, seen) {
		bfsStep:
		while (true) {
			if ($elm$core$List$isEmpty(currentLevel)) {
				return $elm$core$Maybe$Nothing;
			} else {
				var sorted = A2(
					$elm$core$List$sortBy,
					function (_v1) {
						var s = _v1.a;
						return $author$project$Game$Agent$Buckets$troubleCount(s.buckets);
					},
					currentLevel);
				var stepResult = A4($author$project$Game$Agent$Bfs$walkLevel, cap, sorted, seen, _List_Nil);
				if (stepResult.$ === 'Found') {
					var plan = stepResult.a;
					return $elm$core$Maybe$Just(plan);
				} else {
					var nextLevel = stepResult.a;
					var newSeen = stepResult.b;
					var $temp$cap = cap,
						$temp$currentLevel = nextLevel,
						$temp$seen = newSeen;
					cap = $temp$cap;
					currentLevel = $temp$currentLevel;
					seen = $temp$seen;
					continue bfsStep;
				}
			}
		}
	});
var $elm$core$Dict$singleton = F2(
	function (key, value) {
		return A5($elm$core$Dict$RBNode_elm_builtin, $elm$core$Dict$Black, key, value, $elm$core$Dict$RBEmpty_elm_builtin, $elm$core$Dict$RBEmpty_elm_builtin);
	});
var $elm$core$Set$singleton = function (key) {
	return $elm$core$Set$Set_elm_builtin(
		A2($elm$core$Dict$singleton, key, _Utils_Tuple0));
};
var $author$project$Game$Agent$Bfs$bfsWithCap = F2(
	function (cap, initial) {
		if (_Utils_cmp(
			$author$project$Game$Agent$Buckets$troubleCount(initial.buckets),
			cap) > 0) {
			return $elm$core$Maybe$Nothing;
		} else {
			if ($author$project$Game$Agent$Buckets$isVictory(initial.buckets)) {
				return $elm$core$Maybe$Just(_List_Nil);
			} else {
				var initialSig = $author$project$Game$Agent$Bfs$signature(initial);
				return A3(
					$author$project$Game$Agent$Bfs$bfsStep,
					cap,
					_List_fromArray(
						[
							_Utils_Tuple2(initial, _List_Nil)
						]),
					$elm$core$Set$singleton(initialSig));
			}
		}
	});
var $author$project$Game$Agent$Bfs$solveLoop = F3(
	function (cap, maxOuter, initial) {
		solveLoop:
		while (true) {
			if (_Utils_cmp(cap, maxOuter) > 0) {
				return $elm$core$Maybe$Nothing;
			} else {
				var _v0 = A2($author$project$Game$Agent$Bfs$bfsWithCap, cap, initial);
				if (_v0.$ === 'Just') {
					var plan = _v0.a;
					return $elm$core$Maybe$Just(plan);
				} else {
					var $temp$cap = cap + 1,
						$temp$maxOuter = maxOuter,
						$temp$initial = initial;
					cap = $temp$cap;
					maxOuter = $temp$maxOuter;
					initial = $temp$initial;
					continue solveLoop;
				}
			}
		}
	});
var $author$project$Game$Agent$Bfs$solveWithCap = F2(
	function (maxOuter, buckets) {
		var initial = {
			buckets: buckets,
			lineage: $author$project$Game$Agent$Enumerator$initialLineage(buckets)
		};
		return A3($author$project$Game$Agent$Bfs$solveLoop, 1, maxOuter, initial);
	});
var $author$project$Game$Agent$Bfs$solve = $author$project$Game$Agent$Bfs$solveWithCap(10);
var $author$project$Game$Agent$Bfs$solveBoard = function (board) {
	var cardsOf = function (stack) {
		return A2(
			$elm$core$List$map,
			function ($) {
				return $.card;
			},
			stack.boardCards);
	};
	var _v0 = A3(
		$elm$core$List$foldr,
		F2(
			function (stack, _v1) {
				var hs = _v1.a;
				var ts = _v1.b;
				var cards = cardsOf(stack);
				var _v2 = $author$project$Game$StackType$getStackType(cards);
				switch (_v2.$) {
					case 'Set':
						return _Utils_Tuple2(
							A2($elm$core$List$cons, cards, hs),
							ts);
					case 'PureRun':
						return _Utils_Tuple2(
							A2($elm$core$List$cons, cards, hs),
							ts);
					case 'RedBlackRun':
						return _Utils_Tuple2(
							A2($elm$core$List$cons, cards, hs),
							ts);
					default:
						return _Utils_Tuple2(
							hs,
							A2($elm$core$List$cons, cards, ts));
				}
			}),
		_Utils_Tuple2(_List_Nil, _List_Nil),
		board);
	var helper = _v0.a;
	var trouble = _v0.b;
	return $author$project$Game$Agent$Bfs$solve(
		{complete: _List_Nil, growing: _List_Nil, helper: helper, trouble: trouble});
};
var $author$project$Main$Play$nextAgentMove = function (model) {
	var _v0 = model.agentProgram;
	if (_v0.$ === 'Just') {
		if (_v0.a.b) {
			var _v1 = _v0.a;
			var move = _v1.a;
			var rest = _v1.b;
			return $elm$core$Maybe$Just(
				_Utils_Tuple2(move, rest));
		} else {
			return $elm$core$Maybe$Nothing;
		}
	} else {
		var _v2 = $author$project$Game$Agent$Bfs$solveBoard(model.board);
		if ((_v2.$ === 'Just') && _v2.a.b) {
			var _v3 = _v2.a;
			var move = _v3.a;
			var rest = _v3.b;
			return $elm$core$Maybe$Just(
				_Utils_Tuple2(move, rest));
		} else {
			return $elm$core$Maybe$Nothing;
		}
	}
};
var $author$project$Main$Play$noteAgentStatus = function (model) {
	var text = function () {
		var _v0 = model.agentProgram;
		if ((_v0.$ === 'Just') && (!_v0.a.b)) {
			return 'Agent finished its program.';
		} else {
			var _v1 = $author$project$Game$Agent$Bfs$solveBoard(model.board);
			if ((_v1.$ === 'Just') && (!_v1.a.b)) {
				return 'Board is already clean — nothing to do.';
			} else {
				return 'Agent could not find a plan within budget.';
			}
		}
	}();
	return _Utils_update(
		model,
		{
			agentProgram: $elm$core$Maybe$Nothing,
			status: {kind: $author$project$Main$State$Inform, text: text}
		});
};
var $author$project$Main$Msg$BoardRectReceived = function (a) {
	return {$: 'BoardRectReceived', a: a};
};
var $author$project$Main$Play$agentLogEntryWith = function (_v0) {
	var action = _v0.a;
	var gesture = _v0.b;
	return {
		action: action,
		gesturePath: A2(
			$elm$core$Maybe$map,
			function ($) {
				return $.path;
			},
			gesture),
		pathFrame: function () {
			if (gesture.$ === 'Just') {
				var g = gesture.a;
				return g.frame;
			} else {
				return $author$project$Main$State$BoardFrame;
			}
		}()
	};
};
var $elm$core$Task$onError = _Scheduler_onError;
var $elm$core$Task$attempt = F2(
	function (resultToMessage, task) {
		return $elm$core$Task$command(
			$elm$core$Task$Perform(
				A2(
					$elm$core$Task$onError,
					A2(
						$elm$core$Basics$composeL,
						A2($elm$core$Basics$composeL, $elm$core$Task$succeed, resultToMessage),
						$elm$core$Result$Err),
					A2(
						$elm$core$Task$andThen,
						A2(
							$elm$core$Basics$composeL,
							A2($elm$core$Basics$composeL, $elm$core$Task$succeed, resultToMessage),
							$elm$core$Result$Ok),
						task))));
	});
var $author$project$Main$State$boardDomIdFor = function (gameId) {
	return 'lynrummy-board-' + gameId;
};
var $author$project$Game$Agent$Move$bucketStr = function (b) {
	if (b.$ === 'Trouble') {
		return 'trouble';
	} else {
		return 'growing';
	}
};
var $author$project$Game$Agent$Move$deckSuffix = function (d) {
	if (d.$ === 'DeckOne') {
		return '';
	} else {
		return ':1';
	}
};
var $author$project$Game$Agent$Move$suitLetter = function (s) {
	switch (s.$) {
		case 'Club':
			return 'C';
		case 'Diamond':
			return 'D';
		case 'Spade':
			return 'S';
		default:
			return 'H';
	}
};
var $author$project$Game$Card$valueStr = function (v) {
	switch (v.$) {
		case 'Ace':
			return 'A';
		case 'Two':
			return '2';
		case 'Three':
			return '3';
		case 'Four':
			return '4';
		case 'Five':
			return '5';
		case 'Six':
			return '6';
		case 'Seven':
			return '7';
		case 'Eight':
			return '8';
		case 'Nine':
			return '9';
		case 'Ten':
			return 'T';
		case 'Jack':
			return 'J';
		case 'Queen':
			return 'Q';
		default:
			return 'K';
	}
};
var $author$project$Game$Agent$Move$cardLabel = function (c) {
	return _Utils_ap(
		$author$project$Game$Card$valueStr(c.value),
		_Utils_ap(
			$author$project$Game$Agent$Move$suitLetter(c.suit),
			$author$project$Game$Agent$Move$deckSuffix(c.originDeck)));
};
var $author$project$Game$Agent$Move$graduationSuffix = function (graduated) {
	return graduated ? ' [→COMPLETE]' : '';
};
var $author$project$Game$Agent$Move$stackStr = A2(
	$elm$core$Basics$composeR,
	$elm$core$List$map($author$project$Game$Agent$Move$cardLabel),
	$elm$core$String$join(' '));
var $author$project$Game$Agent$Move$spawnedSuffix = function (spawns) {
	if (!spawns.b) {
		return '';
	} else {
		return ' ; spawn TROUBLE: ' + A2(
			$elm$core$String$join,
			', ',
			A2(
				$elm$core$List$map,
				function (s) {
					return '[' + ($author$project$Game$Agent$Move$stackStr(s) + ']');
				},
				spawns));
	}
};
var $author$project$Game$Agent$Move$verbStr = function (v) {
	switch (v.$) {
		case 'Peel':
			return 'peel';
		case 'Pluck':
			return 'pluck';
		case 'Yank':
			return 'yank';
		case 'Steal':
			return 'steal';
		default:
			return 'split_out';
	}
};
var $author$project$Game$Agent$Move$describe = function (move) {
	switch (move.$) {
		case 'ExtractAbsorb':
			var d = move.a;
			return $author$project$Game$Agent$Move$verbStr(d.verb) + (' ' + ($author$project$Game$Agent$Move$cardLabel(d.extCard) + (' from HELPER [' + ($author$project$Game$Agent$Move$stackStr(d.source) + ('], absorb onto ' + ($author$project$Game$Agent$Move$bucketStr(d.targetBucketBefore) + (' [' + ($author$project$Game$Agent$Move$stackStr(d.targetBefore) + ('] → [' + ($author$project$Game$Agent$Move$stackStr(d.result) + (']' + ($author$project$Game$Agent$Move$graduationSuffix(d.graduated) + $author$project$Game$Agent$Move$spawnedSuffix(d.spawned)))))))))))));
		case 'FreePull':
			var d = move.a;
			return 'pull ' + ($author$project$Game$Agent$Move$cardLabel(d.loose) + (' onto ' + ($author$project$Game$Agent$Move$bucketStr(d.targetBucketBefore) + (' [' + ($author$project$Game$Agent$Move$stackStr(d.targetBefore) + ('] → [' + ($author$project$Game$Agent$Move$stackStr(d.result) + (']' + $author$project$Game$Agent$Move$graduationSuffix(d.graduated)))))))));
		case 'Push':
			var d = move.a;
			return 'push TROUBLE [' + ($author$project$Game$Agent$Move$stackStr(d.troubleBefore) + ('] onto HELPER [' + ($author$project$Game$Agent$Move$stackStr(d.targetBefore) + ('] → [' + ($author$project$Game$Agent$Move$stackStr(d.result) + ']')))));
		case 'Splice':
			var d = move.a;
			return 'splice [' + ($author$project$Game$Agent$Move$cardLabel(d.loose) + ('] into HELPER [' + ($author$project$Game$Agent$Move$stackStr(d.source) + ('] → [' + ($author$project$Game$Agent$Move$stackStr(d.leftResult) + ('] + [' + ($author$project$Game$Agent$Move$stackStr(d.rightResult) + ']')))))));
		default:
			var d = move.a;
			var rest = A2(
				$elm$core$List$filter,
				function (c) {
					return !_Utils_eq(c, d.pCard);
				},
				d.newSource);
			var restLabel = A2(
				$elm$core$String$join,
				' ',
				A2($elm$core$List$map, $author$project$Game$Agent$Move$cardLabel, rest));
			var pLabel = $author$project$Game$Agent$Move$cardLabel(d.pCard);
			var shifted = function () {
				var _v1 = d.newSource;
				if (_v1.b) {
					var first = _v1.a;
					return _Utils_eq(first, d.pCard) ? (pLabel + (' + ' + restLabel)) : (restLabel + (' + ' + pLabel));
				} else {
					return pLabel;
				}
			}();
			return 'shift ' + (pLabel + (' to pop ' + ($author$project$Game$Agent$Move$cardLabel(d.stolen) + (' [' + ($author$project$Game$Agent$Move$stackStr(d.newDonor) + (' -> ' + (shifted + (']; absorb onto ' + ($author$project$Game$Agent$Move$bucketStr(d.targetBucketBefore) + (' [' + ($author$project$Game$Agent$Move$stackStr(d.targetBefore) + ('] → [' + ($author$project$Game$Agent$Move$stackStr(d.merged) + (']' + $author$project$Game$Agent$Move$graduationSuffix(d.graduated)))))))))))))));
	}
};
var $elm$browser$Browser$Dom$getElement = _Browser_getElement;
var $author$project$Game$Agent$Verbs$applyChange = F2(
	function (change, board) {
		return _Utils_ap(
			A2(
				$elm$core$List$filter,
				function (s) {
					return !A2(
						$elm$core$List$any,
						$author$project$Game$CardStack$stacksEqual(s),
						change.stacksToRemove);
				},
				board),
			change.stacksToAdd);
	});
var $author$project$Game$Agent$Verbs$findReal = function (target) {
	return A2(
		$elm$core$Basics$composeR,
		$elm$core$List$filter(
			$author$project$Game$CardStack$stacksEqual(target)),
		$elm$core$List$head);
};
var $author$project$Game$Agent$Verbs$applyOnBoard = F2(
	function (action, board) {
		switch (action.$) {
			case 'Split':
				var stack = action.a.stack;
				var cardIndex = action.a.cardIndex;
				var _v1 = A2($author$project$Game$Agent$Verbs$findReal, stack, board);
				if (_v1.$ === 'Just') {
					var real = _v1.a;
					return _Utils_ap(
						A2(
							$elm$core$List$filter,
							A2(
								$elm$core$Basics$composeL,
								$elm$core$Basics$not,
								$author$project$Game$CardStack$stacksEqual(real)),
							board),
						A2($author$project$Game$CardStack$split, cardIndex, real));
				} else {
					return board;
				}
			case 'MergeStack':
				var source = action.a.source;
				var target = action.a.target;
				var side = action.a.side;
				var _v2 = _Utils_Tuple2(
					A2($author$project$Game$Agent$Verbs$findReal, source, board),
					A2($author$project$Game$Agent$Verbs$findReal, target, board));
				if ((_v2.a.$ === 'Just') && (_v2.b.$ === 'Just')) {
					var realSrc = _v2.a.a;
					var realTgt = _v2.b.a;
					var _v3 = A3($author$project$Game$BoardActions$tryStackMerge, realTgt, realSrc, side);
					if (_v3.$ === 'Just') {
						var change = _v3.a;
						return A2($author$project$Game$Agent$Verbs$applyChange, change, board);
					} else {
						return board;
					}
				} else {
					return board;
				}
			case 'MoveStack':
				var stack = action.a.stack;
				var newLoc = action.a.newLoc;
				var _v4 = A2($author$project$Game$Agent$Verbs$findReal, stack, board);
				if (_v4.$ === 'Just') {
					var real = _v4.a;
					return A2(
						$author$project$Game$Agent$Verbs$applyChange,
						A2($author$project$Game$BoardActions$moveStack, real, newLoc),
						board);
				} else {
					return board;
				}
			default:
				return board;
		}
	});
var $author$project$Game$Agent$Verbs$findByCards = function (cards) {
	var cardsOf = function (s) {
		return A2(
			$elm$core$List$map,
			function ($) {
				return $.card;
			},
			s.boardCards);
	};
	return A2(
		$elm$core$Basics$composeR,
		$elm$core$List$filter(
			function (s) {
				return _Utils_eq(
					cardsOf(s),
					cards);
			}),
		$elm$core$List$head);
};
var $author$project$Game$Agent$Verbs$indexOfHelp = F3(
	function (target, cards, i) {
		indexOfHelp:
		while (true) {
			if (!cards.b) {
				return -1;
			} else {
				var c = cards.a;
				var rest = cards.b;
				if (_Utils_eq(c, target)) {
					return i;
				} else {
					var $temp$target = target,
						$temp$cards = rest,
						$temp$i = i + 1;
					target = $temp$target;
					cards = $temp$cards;
					i = $temp$i;
					continue indexOfHelp;
				}
			}
		}
	});
var $author$project$Game$Agent$Verbs$indexOf = F2(
	function (target, cards) {
		return A3($author$project$Game$Agent$Verbs$indexOfHelp, target, cards, 0);
	});
var $author$project$Game$Agent$Verbs$interiorSetReassemble = F2(
	function (d, board) {
		var ci = A2($author$project$Game$Agent$Verbs$indexOf, d.extCard, d.source);
		var leftChunk = A2($elm$core$List$take, ci, d.source);
		var tailChunk = A2($elm$core$List$drop, ci + 1, d.source);
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Agent$Verbs$findByCards, tailChunk, board),
			A2($author$project$Game$Agent$Verbs$findByCards, leftChunk, board));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var tail = _v0.a.a;
			var left = _v0.b.a;
			return _List_fromArray(
				[
					$author$project$Game$WireAction$MergeStack(
					{side: $author$project$Game$BoardActions$Right, source: tail, target: left})
				]);
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Verbs$allSameValue = function (cards) {
	if (!cards.b) {
		return true;
	} else {
		var first = cards.a;
		var rest = cards.b;
		return A2(
			$elm$core$List$all,
			function (c) {
				return _Utils_eq(c.value, first.value);
			},
			rest);
	}
};
var $author$project$Game$Agent$Verbs$isInteriorSetPeel = function (d) {
	var n = $elm$core$List$length(d.source);
	var ci = A2($author$project$Game$Agent$Verbs$indexOf, d.extCard, d.source);
	return _Utils_eq(d.verb, $author$project$Game$Agent$Move$Peel) && ($author$project$Game$Agent$Verbs$allSameValue(d.source) && ((ci > 0) && (_Utils_cmp(ci, n - 1) < 0)));
};
var $author$project$Game$Agent$Verbs$isStealFromSet = function (d) {
	return _Utils_eq(d.verb, $author$project$Game$Agent$Move$Steal) && ($author$project$Game$Agent$Verbs$allSameValue(d.source) && ($elm$core$List$length(d.source) === 3));
};
var $author$project$Game$Agent$Verbs$splitCardIndex = F2(
	function (k, n) {
		return (_Utils_cmp(k, (n / 2) | 0) < 1) ? (k - 1) : k;
	});
var $author$project$Game$Agent$Verbs$planSplit = F3(
	function (board, source, k) {
		var n = $elm$core$List$length(source);
		var donorStack = A2($author$project$Game$Agent$Verbs$findByCards, source, board);
		var ci = A2($author$project$Game$Agent$Verbs$splitCardIndex, k, n);
		if (donorStack.$ === 'Just') {
			var real = donorStack.a;
			var splitPrim = $author$project$Game$WireAction$Split(
				{cardIndex: ci, stack: real});
			return _Utils_Tuple2(
				_List_fromArray(
					[splitPrim]),
				A2($author$project$Game$Agent$Verbs$applyOnBoard, splitPrim, board));
		} else {
			return _Utils_Tuple2(_List_Nil, board);
		}
	});
var $author$project$Game$Agent$Verbs$isolateCard = F3(
	function (board, source, ci) {
		var n = $elm$core$List$length(source);
		var _v0 = A2($author$project$Game$Agent$Verbs$findByCards, source, board);
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(_List_Nil, board);
		} else {
			if ((!ci) && (n > 1)) {
				var _v1 = A3($author$project$Game$Agent$Verbs$planSplit, board, source, 1);
				var pre = _v1.a;
				var board1 = _v1.b;
				return _Utils_Tuple2(pre, board1);
			} else {
				if (_Utils_eq(ci, n - 1) && (n > 1)) {
					var _v2 = A3($author$project$Game$Agent$Verbs$planSplit, board, source, n - 1);
					var pre = _v2.a;
					var board1 = _v2.b;
					return _Utils_Tuple2(pre, board1);
				} else {
					var rightChunk = A2($elm$core$List$drop, ci, source);
					var _v3 = A3($author$project$Game$Agent$Verbs$planSplit, board, source, ci);
					var firstPrims = _v3.a;
					var afterFirst = _v3.b;
					var _v4 = A3($author$project$Game$Agent$Verbs$planSplit, afterFirst, rightChunk, 1);
					var secondPrims = _v4.a;
					var afterSecond = _v4.b;
					return _Utils_Tuple2(
						_Utils_ap(firstPrims, secondPrims),
						afterSecond);
				}
			}
		}
	});
var $author$project$Game$Agent$Verbs$toBoardSide = function (s) {
	if (s.$ === 'LeftSide') {
		return $author$project$Game$BoardActions$Left;
	} else {
		return $author$project$Game$BoardActions$Right;
	}
};
var $author$project$Game$Agent$Verbs$stealFromSetPrims = F2(
	function (board, d) {
		var _v0 = A2($author$project$Game$Agent$Verbs$findByCards, d.source, board);
		if (_v0.$ === 'Nothing') {
			return _List_Nil;
		} else {
			var src = _v0.a;
			var n = $elm$core$List$length(d.source);
			var ci = A2($author$project$Game$Agent$Verbs$indexOf, d.extCard, d.source);
			var _v1 = _Utils_eq(ci, n - 1) ? _Utils_Tuple2(
				A2($author$project$Game$Agent$Verbs$splitCardIndex, n - 1, n),
				A2($elm$core$List$take, n - 1, d.source)) : _Utils_Tuple2(
				A2($author$project$Game$Agent$Verbs$splitCardIndex, 1, n),
				A2($elm$core$List$drop, 1, d.source));
			var firstSplitIndex = _v1.a;
			var residueCards = _v1.b;
			var first = $author$project$Game$WireAction$Split(
				{cardIndex: firstSplitIndex, stack: src});
			var boardAfterFirst = A2($author$project$Game$Agent$Verbs$applyOnBoard, first, board);
			var _v2 = A2($author$project$Game$Agent$Verbs$findByCards, residueCards, boardAfterFirst);
			if (_v2.$ === 'Nothing') {
				return _List_Nil;
			} else {
				var residueStack = _v2.a;
				var second = $author$project$Game$WireAction$Split(
					{
						cardIndex: A2(
							$author$project$Game$Agent$Verbs$splitCardIndex,
							1,
							$elm$core$List$length(residueCards)),
						stack: residueStack
					});
				var boardAfterSecond = A2($author$project$Game$Agent$Verbs$applyOnBoard, second, boardAfterFirst);
				var _v3 = _Utils_Tuple2(
					A2(
						$author$project$Game$Agent$Verbs$findByCards,
						_List_fromArray(
							[d.extCard]),
						boardAfterSecond),
					A2($author$project$Game$Agent$Verbs$findByCards, d.targetBefore, boardAfterSecond));
				if ((_v3.a.$ === 'Just') && (_v3.b.$ === 'Just')) {
					var extSt = _v3.a.a;
					var tgt = _v3.b.a;
					return _List_fromArray(
						[
							first,
							second,
							$author$project$Game$WireAction$MergeStack(
							{
								side: $author$project$Game$Agent$Verbs$toBoardSide(d.side),
								source: extSt,
								target: tgt
							})
						]);
				} else {
					return _List_Nil;
				}
			}
		}
	});
var $author$project$Game$Agent$Verbs$extractAbsorbPrims = F2(
	function (board, d) {
		if ($author$project$Game$Agent$Verbs$isStealFromSet(d)) {
			return A2($author$project$Game$Agent$Verbs$stealFromSetPrims, board, d);
		} else {
			var ci = A2($author$project$Game$Agent$Verbs$indexOf, d.extCard, d.source);
			var _v0 = A3($author$project$Game$Agent$Verbs$isolateCard, board, d.source, ci);
			var isolatePrims = _v0.a;
			var postIsolate = _v0.b;
			var followUp = $author$project$Game$Agent$Verbs$isInteriorSetPeel(d) ? A2($author$project$Game$Agent$Verbs$interiorSetReassemble, d, postIsolate) : _List_Nil;
			var postFollowUp = A3($elm$core$List$foldl, $author$project$Game$Agent$Verbs$applyOnBoard, postIsolate, followUp);
			var absorbStep = function () {
				var _v1 = _Utils_Tuple2(
					A2(
						$author$project$Game$Agent$Verbs$findByCards,
						_List_fromArray(
							[d.extCard]),
						postFollowUp),
					A2($author$project$Game$Agent$Verbs$findByCards, d.targetBefore, postFollowUp));
				if ((_v1.a.$ === 'Just') && (_v1.b.$ === 'Just')) {
					var singleton = _v1.a.a;
					var target = _v1.b.a;
					return _List_fromArray(
						[
							$author$project$Game$WireAction$MergeStack(
							{
								side: $author$project$Game$Agent$Verbs$toBoardSide(d.side),
								source: singleton,
								target: target
							})
						]);
				} else {
					return _List_Nil;
				}
			}();
			return _Utils_ap(
				isolatePrims,
				_Utils_ap(followUp, absorbStep));
		}
	});
var $author$project$Game$Agent$Verbs$freePullPrims = F2(
	function (board, d) {
		var _v0 = _Utils_Tuple2(
			A2(
				$author$project$Game$Agent$Verbs$findByCards,
				_List_fromArray(
					[d.loose]),
				board),
			A2($author$project$Game$Agent$Verbs$findByCards, d.targetBefore, board));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var looseStack = _v0.a.a;
			var target = _v0.b.a;
			return _List_fromArray(
				[
					$author$project$Game$WireAction$MergeStack(
					{
						side: $author$project$Game$Agent$Verbs$toBoardSide(d.side),
						source: looseStack,
						target: target
					})
				]);
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Verbs$pushPrims = F2(
	function (board, d) {
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Agent$Verbs$findByCards, d.troubleBefore, board),
			A2($author$project$Game$Agent$Verbs$findByCards, d.targetBefore, board));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var src = _v0.a.a;
			var target = _v0.b.a;
			return _List_fromArray(
				[
					$author$project$Game$WireAction$MergeStack(
					{
						side: $author$project$Game$Agent$Verbs$toBoardSide(d.side),
						source: src,
						target: target
					})
				]);
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Verbs$interiorSetReassembleDonor = F2(
	function (d, board) {
		var ci = A2($author$project$Game$Agent$Verbs$indexOf, d.pCard, d.donor);
		var leftChunk = A2($elm$core$List$take, ci, d.donor);
		var tailChunk = A2($elm$core$List$drop, ci + 1, d.donor);
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Agent$Verbs$findByCards, tailChunk, board),
			A2($author$project$Game$Agent$Verbs$findByCards, leftChunk, board));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var tail = _v0.a.a;
			var left = _v0.b.a;
			return _List_fromArray(
				[
					$author$project$Game$WireAction$MergeStack(
					{side: $author$project$Game$BoardActions$Right, source: tail, target: left})
				]);
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Verbs$shiftPrims = F2(
	function (board, d) {
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Agent$Verbs$findByCards, d.donor, board),
			A2($author$project$Game$Agent$Verbs$findByCards, d.source, board));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var pi = A2($author$project$Game$Agent$Verbs$indexOf, d.pCard, d.donor);
			var donorIsSet = $author$project$Game$Agent$Verbs$allSameValue(d.donor);
			var _v1 = function () {
				var _v2 = d.whichEnd;
				if (_v2.$ === 'LeftEnd') {
					return _Utils_Tuple3(
						$author$project$Game$BoardActions$Right,
						_Utils_ap(
							d.source,
							_List_fromArray(
								[d.pCard])),
						1);
				} else {
					return _Utils_Tuple3(
						$author$project$Game$BoardActions$Left,
						A2($elm$core$List$cons, d.pCard, d.source),
						$elm$core$List$length(d.source));
				}
			}();
			var pSide = _v1.a;
			var augmentedSource = _v1.b;
			var splitK = _v1.c;
			var _v3 = A3($author$project$Game$Agent$Verbs$isolateCard, board, d.donor, pi);
			var donorPrims = _v3.a;
			var postDonor = _v3.b;
			var donorFollowUp = (donorIsSet && ((pi > 0) && (_Utils_cmp(
				pi,
				$elm$core$List$length(d.donor) - 1) < 0))) ? A2($author$project$Game$Agent$Verbs$interiorSetReassembleDonor, d, postDonor) : _List_Nil;
			var postDonorAssembled = A3($elm$core$List$foldl, $author$project$Game$Agent$Verbs$applyOnBoard, postDonor, donorFollowUp);
			var pMergeStep = function () {
				var _v6 = _Utils_Tuple2(
					A2(
						$author$project$Game$Agent$Verbs$findByCards,
						_List_fromArray(
							[d.pCard]),
						postDonorAssembled),
					A2($author$project$Game$Agent$Verbs$findByCards, d.source, postDonorAssembled));
				if ((_v6.a.$ === 'Just') && (_v6.b.$ === 'Just')) {
					var pSt = _v6.a.a;
					var srcSt = _v6.b.a;
					return _List_fromArray(
						[
							$author$project$Game$WireAction$MergeStack(
							{side: pSide, source: pSt, target: srcSt})
						]);
				} else {
					return _List_Nil;
				}
			}();
			var postPMerge = A3($elm$core$List$foldl, $author$project$Game$Agent$Verbs$applyOnBoard, postDonorAssembled, pMergeStep);
			var _v4 = A3($author$project$Game$Agent$Verbs$planSplit, postPMerge, augmentedSource, splitK);
			var stolenSplitPrims = _v4.a;
			var postStolenSplit = _v4.b;
			var stolenMergeStep = function () {
				var _v5 = _Utils_Tuple2(
					A2(
						$author$project$Game$Agent$Verbs$findByCards,
						_List_fromArray(
							[d.stolen]),
						postStolenSplit),
					A2($author$project$Game$Agent$Verbs$findByCards, d.targetBefore, postStolenSplit));
				if ((_v5.a.$ === 'Just') && (_v5.b.$ === 'Just')) {
					var stlnSt = _v5.a.a;
					var tgtSt = _v5.b.a;
					return _List_fromArray(
						[
							$author$project$Game$WireAction$MergeStack(
							{
								side: $author$project$Game$Agent$Verbs$toBoardSide(d.side),
								source: stlnSt,
								target: tgtSt
							})
						]);
				} else {
					return _List_Nil;
				}
			}();
			return _Utils_ap(
				donorPrims,
				_Utils_ap(
					donorFollowUp,
					_Utils_ap(
						pMergeStep,
						_Utils_ap(stolenSplitPrims, stolenMergeStep))));
		} else {
			return _List_Nil;
		}
	});
var $author$project$Game$Agent$Verbs$splicePrims = F2(
	function (board, d) {
		var rightChunk = A2($elm$core$List$drop, d.k, d.source);
		var leftChunk = A2($elm$core$List$take, d.k, d.source);
		var _v0 = A3($author$project$Game$Agent$Verbs$planSplit, board, d.source, d.k);
		var splitPrims = _v0.a;
		var postSplit = _v0.b;
		var mergeStep = function () {
			var _v1 = d.side;
			if (_v1.$ === 'LeftSide') {
				var _v2 = _Utils_Tuple2(
					A2(
						$author$project$Game$Agent$Verbs$findByCards,
						_List_fromArray(
							[d.loose]),
						postSplit),
					A2($author$project$Game$Agent$Verbs$findByCards, leftChunk, postSplit));
				if ((_v2.a.$ === 'Just') && (_v2.b.$ === 'Just')) {
					var looseSt = _v2.a.a;
					var leftSt = _v2.b.a;
					return _List_fromArray(
						[
							$author$project$Game$WireAction$MergeStack(
							{side: $author$project$Game$BoardActions$Right, source: looseSt, target: leftSt})
						]);
				} else {
					return _List_Nil;
				}
			} else {
				var _v3 = _Utils_Tuple2(
					A2(
						$author$project$Game$Agent$Verbs$findByCards,
						_List_fromArray(
							[d.loose]),
						postSplit),
					A2($author$project$Game$Agent$Verbs$findByCards, rightChunk, postSplit));
				if ((_v3.a.$ === 'Just') && (_v3.b.$ === 'Just')) {
					var looseSt = _v3.a.a;
					var rightSt = _v3.b.a;
					return _List_fromArray(
						[
							$author$project$Game$WireAction$MergeStack(
							{side: $author$project$Game$BoardActions$Left, source: looseSt, target: rightSt})
						]);
				} else {
					return _List_Nil;
				}
			}
		}();
		return _Utils_ap(splitPrims, mergeStep);
	});
var $author$project$Game$Agent$Verbs$moveToPrimitives = F2(
	function (board, move) {
		switch (move.$) {
			case 'ExtractAbsorb':
				var d = move.a;
				return A2($author$project$Game$Agent$Verbs$extractAbsorbPrims, board, d);
			case 'FreePull':
				var d = move.a;
				return A2($author$project$Game$Agent$Verbs$freePullPrims, board, d);
			case 'Push':
				var d = move.a;
				return A2($author$project$Game$Agent$Verbs$pushPrims, board, d);
			case 'Splice':
				var d = move.a;
				return A2($author$project$Game$Agent$Verbs$splicePrims, board, d);
			default:
				var d = move.a;
				return A2($author$project$Game$Agent$Verbs$shiftPrims, board, d);
		}
	});
var $author$project$Game$Agent$GeometryPlan$applyChange = F2(
	function (change, board) {
		return _Utils_ap(
			A2(
				$elm$core$List$filter,
				function (s) {
					return !A2(
						$elm$core$List$any,
						$author$project$Game$CardStack$stacksEqual(s),
						change.stacksToRemove);
				},
				board),
			change.stacksToAdd);
	});
var $author$project$Game$Agent$GeometryPlan$findReal = function (target) {
	return A2(
		$elm$core$Basics$composeR,
		$elm$core$List$filter(
			$author$project$Game$CardStack$stacksEqual(target)),
		$elm$core$List$head);
};
var $author$project$Game$Agent$GeometryPlan$applyOnBoard = F2(
	function (action, board) {
		switch (action.$) {
			case 'Split':
				var stack = action.a.stack;
				var cardIndex = action.a.cardIndex;
				var _v1 = A2($author$project$Game$Agent$GeometryPlan$findReal, stack, board);
				if (_v1.$ === 'Just') {
					var real = _v1.a;
					return _Utils_ap(
						A2(
							$elm$core$List$filter,
							A2(
								$elm$core$Basics$composeL,
								$elm$core$Basics$not,
								$author$project$Game$CardStack$stacksEqual(real)),
							board),
						A2($author$project$Game$CardStack$split, cardIndex, real));
				} else {
					return board;
				}
			case 'MergeStack':
				var source = action.a.source;
				var target = action.a.target;
				var side = action.a.side;
				var _v2 = _Utils_Tuple2(
					A2($author$project$Game$Agent$GeometryPlan$findReal, source, board),
					A2($author$project$Game$Agent$GeometryPlan$findReal, target, board));
				if ((_v2.a.$ === 'Just') && (_v2.b.$ === 'Just')) {
					var realSrc = _v2.a.a;
					var realTgt = _v2.b.a;
					var _v3 = A3($author$project$Game$BoardActions$tryStackMerge, realTgt, realSrc, side);
					if (_v3.$ === 'Just') {
						var change = _v3.a;
						return A2($author$project$Game$Agent$GeometryPlan$applyChange, change, board);
					} else {
						return board;
					}
				} else {
					return board;
				}
			case 'MoveStack':
				var stack = action.a.stack;
				var newLoc = action.a.newLoc;
				var _v4 = A2($author$project$Game$Agent$GeometryPlan$findReal, stack, board);
				if (_v4.$ === 'Just') {
					var real = _v4.a;
					return A2(
						$author$project$Game$Agent$GeometryPlan$applyChange,
						A2($author$project$Game$BoardActions$moveStack, real, newLoc),
						board);
				} else {
					return board;
				}
			default:
				return board;
		}
	});
var $author$project$Game$Agent$GeometryPlan$stackBoundingRect = function (s) {
	var n = $elm$core$List$length(s.boardCards);
	var width = (n <= 0) ? 0 : (27 + ((n - 1) * $author$project$Game$BoardGeometry$cardPitch));
	return {bottom: s.loc.top + 40, left: s.loc.left, right: s.loc.left + width, top: s.loc.top};
};
var $author$project$Game$Agent$GeometryPlan$anyPackGapOverlap = F2(
	function (preExisting, newStack) {
		var rect = $author$project$Game$Agent$GeometryPlan$stackBoundingRect(newStack);
		var padded = {bottom: rect.bottom + 30, left: rect.left - 30, right: rect.right + 30, top: rect.top - 30};
		return A2(
			$elm$core$List$any,
			function (old) {
				var otherRect = $author$project$Game$Agent$GeometryPlan$stackBoundingRect(old);
				return (_Utils_cmp(padded.left, otherRect.right) < 0) && ((_Utils_cmp(padded.right, otherRect.left) > 0) && ((_Utils_cmp(padded.top, otherRect.bottom) < 0) && (_Utils_cmp(padded.bottom, otherRect.top) > 0)));
			},
			preExisting);
	});
var $author$project$Game$Agent$GeometryPlan$defaultBounds = {margin: 7, maxHeight: 600, maxWidth: 800};
var $author$project$Game$Agent$GeometryPlan$stackKey = function (s) {
	return _Utils_Tuple2(
		s.loc,
		A2(
			$elm$core$List$map,
			function ($) {
				return $.card;
			},
			s.boardCards));
};
var $author$project$Game$Agent$GeometryPlan$isCleanAfterAction = F2(
	function (preBoard, postBoard) {
		var preKeys = A2($elm$core$List$map, $author$project$Game$Agent$GeometryPlan$stackKey, preBoard);
		var preExisting = A2(
			$elm$core$List$filter,
			function (s) {
				return A2(
					$elm$core$List$member,
					$author$project$Game$Agent$GeometryPlan$stackKey(s),
					preKeys);
			},
			postBoard);
		var newStacks = A2(
			$elm$core$List$filter,
			function (s) {
				return !A2(
					$elm$core$List$member,
					$author$project$Game$Agent$GeometryPlan$stackKey(s),
					preKeys);
			},
			postBoard);
		var legalErrors = A2($author$project$Game$BoardGeometry$validateBoardGeometry, postBoard, $author$project$Game$Agent$GeometryPlan$defaultBounds);
		return (!$elm$core$List$isEmpty(legalErrors)) ? false : (!A2(
			$elm$core$List$any,
			$author$project$Game$Agent$GeometryPlan$anyPackGapOverlap(preExisting),
			newStacks));
	});
var $author$project$Game$Agent$GeometryPlan$findByContent = function (ref) {
	var cardsOf = function (s) {
		return A2(
			$elm$core$List$map,
			function ($) {
				return $.card;
			},
			s.boardCards);
	};
	var refCards = cardsOf(ref);
	return A2(
		$elm$core$Basics$composeR,
		$elm$core$List$filter(
			function (s) {
				return _Utils_eq(
					cardsOf(s),
					refCards);
			}),
		$elm$core$List$head);
};
var $author$project$Game$PlaceStack$antiAlignPx = 2;
var $author$project$Game$PlaceStack$boardMaxHeight = 600;
var $author$project$Game$PlaceStack$boardMaxWidth = 800;
var $author$project$Game$PlaceStack$antiAlign = F4(
	function (left, top, newW, newH) {
		return {
			left: A2($elm$core$Basics$min, left + $author$project$Game$PlaceStack$antiAlignPx, $author$project$Game$PlaceStack$boardMaxWidth - newW),
			top: A2($elm$core$Basics$min, top + $author$project$Game$PlaceStack$antiAlignPx, $author$project$Game$PlaceStack$boardMaxHeight - newH)
		};
	});
var $author$project$Game$PlaceStack$boardMargin = 7;
var $author$project$Game$PlaceStack$boardStartLeft = 24;
var $author$project$Game$PlaceStack$boardStartTop = 24;
var $author$project$Game$PlaceStack$cardHeight = 40;
var $elm$core$Basics$clamp = F3(
	function (low, high, number) {
		return (_Utils_cmp(number, low) < 0) ? low : ((_Utils_cmp(number, high) > 0) ? high : number);
	});
var $author$project$Game$PlaceStack$placeStep = 10;
var $author$project$Game$PlaceStack$rectsOverlap = F2(
	function (a, b) {
		return (_Utils_cmp(a.left, b.right) < 0) && ((_Utils_cmp(a.right, b.left) > 0) && ((_Utils_cmp(a.top, b.bottom) < 0) && (_Utils_cmp(a.bottom, b.top) > 0)));
	});
var $author$project$Game$PlaceStack$gridSweepRow = F5(
	function (rects, newW, newH, top, left) {
		gridSweepRow:
		while (true) {
			if (_Utils_cmp(left + newW, $author$project$Game$PlaceStack$boardMaxWidth) > 0) {
				return $elm$core$Maybe$Nothing;
			} else {
				var padded = {bottom: (top + newH) + $author$project$Game$PlaceStack$boardMargin, left: left - $author$project$Game$PlaceStack$boardMargin, right: (left + newW) + $author$project$Game$PlaceStack$boardMargin, top: top - $author$project$Game$PlaceStack$boardMargin};
				var collides = A2(
					$elm$core$List$any,
					$author$project$Game$PlaceStack$rectsOverlap(padded),
					rects);
				if (collides) {
					var $temp$rects = rects,
						$temp$newW = newW,
						$temp$newH = newH,
						$temp$top = top,
						$temp$left = left + $author$project$Game$PlaceStack$placeStep;
					rects = $temp$rects;
					newW = $temp$newW;
					newH = $temp$newH;
					top = $temp$top;
					left = $temp$left;
					continue gridSweepRow;
				} else {
					return $elm$core$Maybe$Just(
						{left: left, top: top});
				}
			}
		}
	});
var $author$project$Game$PlaceStack$gridSweepLoop = F4(
	function (rects, newW, newH, top) {
		gridSweepLoop:
		while (true) {
			if (_Utils_cmp(top + newH, $author$project$Game$PlaceStack$boardMaxHeight) > 0) {
				return $elm$core$Maybe$Nothing;
			} else {
				var _v0 = A5($author$project$Game$PlaceStack$gridSweepRow, rects, newW, newH, top, 0);
				if (_v0.$ === 'Just') {
					var loc = _v0.a;
					return $elm$core$Maybe$Just(loc);
				} else {
					var $temp$rects = rects,
						$temp$newW = newW,
						$temp$newH = newH,
						$temp$top = top + $author$project$Game$PlaceStack$placeStep;
					rects = $temp$rects;
					newW = $temp$newW;
					newH = $temp$newH;
					top = $temp$top;
					continue gridSweepLoop;
				}
			}
		}
	});
var $author$project$Game$PlaceStack$gridSweep = F3(
	function (existingRects, newW, newH) {
		var _v0 = A4($author$project$Game$PlaceStack$gridSweepLoop, existingRects, newW, newH, 0);
		if (_v0.$ === 'Just') {
			var loc = _v0.a;
			return loc;
		} else {
			return {
				left: 0,
				top: A2($elm$core$Basics$max, 0, $author$project$Game$PlaceStack$boardMaxHeight - newH)
			};
		}
	});
var $author$project$Game$PlaceStack$humanPreferredOriginLeft = 50;
var $author$project$Game$PlaceStack$humanPreferredOriginTop = 90;
var $author$project$Game$PlaceStack$packStep = 15;
var $author$project$Game$PlaceStack$packGapX = 30;
var $author$project$Game$PlaceStack$packGapY = 30;
var $author$project$Game$PlaceStack$packGapClears = F5(
	function (rects, left, top, newW, newH) {
		var padded = {bottom: (top + newH) + $author$project$Game$PlaceStack$packGapY, left: left - $author$project$Game$PlaceStack$packGapX, right: (left + newW) + $author$project$Game$PlaceStack$packGapX, top: top - $author$project$Game$PlaceStack$packGapY};
		return !A2(
			$elm$core$List$any,
			$author$project$Game$PlaceStack$rectsOverlap(padded),
			rects);
	});
var $author$project$Game$PlaceStack$packedScanTop = F3(
	function (args, left, top) {
		packedScanTop:
		while (true) {
			if (_Utils_cmp(top, args.maxTop) > 0) {
				return $elm$core$Maybe$Nothing;
			} else {
				if (A5($author$project$Game$PlaceStack$packGapClears, args.existingRects, left, top, args.newW, args.newH)) {
					return $elm$core$Maybe$Just(
						{left: left, top: top});
				} else {
					var $temp$args = args,
						$temp$left = left,
						$temp$top = top + $author$project$Game$PlaceStack$packStep;
					args = $temp$args;
					left = $temp$left;
					top = $temp$top;
					continue packedScanTop;
				}
			}
		}
	});
var $author$project$Game$PlaceStack$packedScanLeft = F2(
	function (args, left) {
		packedScanLeft:
		while (true) {
			if (_Utils_cmp(left, args.maxLeft) > 0) {
				return $elm$core$Maybe$Nothing;
			} else {
				var _v0 = A3($author$project$Game$PlaceStack$packedScanTop, args, left, args.minTop);
				if (_v0.$ === 'Just') {
					var hit = _v0.a;
					return $elm$core$Maybe$Just(hit);
				} else {
					var $temp$args = args,
						$temp$left = left + $author$project$Game$PlaceStack$packStep;
					args = $temp$args;
					left = $temp$left;
					continue packedScanLeft;
				}
			}
		}
	});
var $author$project$Game$PlaceStack$packedScan = function (args) {
	return A2($author$project$Game$PlaceStack$packedScanLeft, args, args.minLeft);
};
var $author$project$Game$PlaceStack$cardPitch = $author$project$Game$CardStack$cardWidth + 6;
var $author$project$Game$PlaceStack$stackWidth = function (cardCount) {
	return (cardCount <= 0) ? 0 : ($author$project$Game$CardStack$cardWidth + ((cardCount - 1) * $author$project$Game$PlaceStack$cardPitch));
};
var $author$project$Game$PlaceStack$stackRect = function (stack) {
	return {
		bottom: stack.loc.top + $author$project$Game$PlaceStack$cardHeight,
		left: stack.loc.left,
		right: stack.loc.left + $author$project$Game$PlaceStack$stackWidth(
			$elm$core$List$length(stack.boardCards)),
		top: stack.loc.top
	};
};
var $author$project$Game$PlaceStack$findOpenLoc = F2(
	function (existing, cardCount) {
		var newW = $author$project$Game$PlaceStack$stackWidth(cardCount);
		var newH = $author$project$Game$PlaceStack$cardHeight;
		var existingRects = A2($elm$core$List$map, $author$project$Game$PlaceStack$stackRect, existing);
		if ($elm$core$List$isEmpty(existingRects)) {
			return A4($author$project$Game$PlaceStack$antiAlign, $author$project$Game$PlaceStack$boardStartLeft, $author$project$Game$PlaceStack$boardStartTop, newW, newH);
		} else {
			var minTop = $author$project$Game$PlaceStack$boardMargin;
			var minLeft = $author$project$Game$PlaceStack$boardMargin;
			var maxTop = ($author$project$Game$PlaceStack$boardMaxHeight - newH) - $author$project$Game$PlaceStack$boardMargin;
			var startTop = A3($elm$core$Basics$clamp, minTop, maxTop, $author$project$Game$PlaceStack$humanPreferredOriginTop);
			var maxLeft = ($author$project$Game$PlaceStack$boardMaxWidth - newW) - $author$project$Game$PlaceStack$boardMargin;
			var startLeft = A3($elm$core$Basics$clamp, minLeft, maxLeft, $author$project$Game$PlaceStack$humanPreferredOriginLeft);
			var _v0 = $author$project$Game$PlaceStack$packedScan(
				{existingRects: existingRects, maxLeft: maxLeft, maxTop: maxTop, minLeft: startLeft, minTop: startTop, newH: newH, newW: newW});
			if (_v0.$ === 'Just') {
				var loc = _v0.a;
				return A4($author$project$Game$PlaceStack$antiAlign, loc.left, loc.top, newW, newH);
			} else {
				var _v1 = $author$project$Game$PlaceStack$packedScan(
					{existingRects: existingRects, maxLeft: maxLeft, maxTop: maxTop, minLeft: minLeft, minTop: minTop, newH: newH, newW: newW});
				if (_v1.$ === 'Just') {
					var loc = _v1.a;
					return A4($author$project$Game$PlaceStack$antiAlign, loc.left, loc.top, newW, newH);
				} else {
					return A3($author$project$Game$PlaceStack$gridSweep, existingRects, newW, newH);
				}
			}
		}
	});
var $author$project$Game$Agent$GeometryPlan$preFlightMerge = F4(
	function (board, source, target, side) {
		var targetSize = $elm$core$List$length(target.boardCards);
		var sourceSize = $elm$core$List$length(source.boardCards);
		var others = A2(
			$elm$core$List$filter,
			function (s) {
				return (!A2($author$project$Game$CardStack$stacksEqual, s, source)) && (!A2($author$project$Game$CardStack$stacksEqual, s, target));
			},
			board);
		var finalSize = sourceSize + targetSize;
		var finalLoc = A2($author$project$Game$PlaceStack$findOpenLoc, others, finalSize);
		var targetLoc = function () {
			if (side.$ === 'Left') {
				return {left: finalLoc.left + (sourceSize * $author$project$Game$BoardGeometry$cardPitch), top: finalLoc.top};
			} else {
				return finalLoc;
			}
		}();
		if (_Utils_eq(targetLoc, target.loc)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var movePrim = $author$project$Game$WireAction$MoveStack(
				{newLoc: targetLoc, stack: target});
			var afterMove = A2($author$project$Game$Agent$GeometryPlan$applyOnBoard, movePrim, board);
			var movedSource = A2($author$project$Game$Agent$GeometryPlan$findByContent, source, afterMove);
			var movedTarget = A2($author$project$Game$Agent$GeometryPlan$findByContent, target, afterMove);
			var _v0 = _Utils_Tuple2(movedSource, movedTarget);
			if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
				var src = _v0.a.a;
				var tgt = _v0.b.a;
				var newMerge = $author$project$Game$WireAction$MergeStack(
					{side: side, source: src, target: tgt});
				var afterMerge = A2($author$project$Game$Agent$GeometryPlan$applyOnBoard, newMerge, afterMove);
				return $elm$core$Maybe$Just(
					_Utils_Tuple3(movePrim, newMerge, afterMerge));
			} else {
				return $elm$core$Maybe$Nothing;
			}
		}
	});
var $author$project$Game$Agent$GeometryPlan$preFlightSplit = F3(
	function (board, stack, cardIndex) {
		var sourceSize = $elm$core$List$length(stack.boardCards);
		var others = A2(
			$elm$core$List$filter,
			A2(
				$elm$core$Basics$composeL,
				$elm$core$Basics$not,
				$author$project$Game$CardStack$stacksEqual(stack)),
			board);
		var newLoc = A2($author$project$Game$PlaceStack$findOpenLoc, others, sourceSize);
		if (_Utils_eq(newLoc, stack.loc)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var movePrim = $author$project$Game$WireAction$MoveStack(
				{newLoc: newLoc, stack: stack});
			var afterMove = A2($author$project$Game$Agent$GeometryPlan$applyOnBoard, movePrim, board);
			var _v0 = A2($author$project$Game$Agent$GeometryPlan$findByContent, stack, afterMove);
			if (_v0.$ === 'Just') {
				var relocated = _v0.a;
				var newSplit = $author$project$Game$WireAction$Split(
					{cardIndex: cardIndex, stack: relocated});
				var afterSplit = A2($author$project$Game$Agent$GeometryPlan$applyOnBoard, newSplit, afterMove);
				return $elm$core$Maybe$Just(
					_Utils_Tuple3(movePrim, newSplit, afterSplit));
			} else {
				return $elm$core$Maybe$Nothing;
			}
		}
	});
var $author$project$Game$Agent$GeometryPlan$preFlight = F2(
	function (board, action) {
		switch (action.$) {
			case 'Split':
				var p = action.a;
				return A3($author$project$Game$Agent$GeometryPlan$preFlightSplit, board, p.stack, p.cardIndex);
			case 'MergeStack':
				var p = action.a;
				return A4($author$project$Game$Agent$GeometryPlan$preFlightMerge, board, p.source, p.target, p.side);
			default:
				return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$Agent$GeometryPlan$resolveAction = F2(
	function (board, action) {
		switch (action.$) {
			case 'Split':
				var p = action.a;
				var _v1 = A2($author$project$Game$Agent$GeometryPlan$findByContent, p.stack, board);
				if (_v1.$ === 'Just') {
					var live = _v1.a;
					return $author$project$Game$WireAction$Split(
						_Utils_update(
							p,
							{stack: live}));
				} else {
					return action;
				}
			case 'MergeStack':
				var p = action.a;
				var _v2 = _Utils_Tuple2(
					A2($author$project$Game$Agent$GeometryPlan$findByContent, p.source, board),
					A2($author$project$Game$Agent$GeometryPlan$findByContent, p.target, board));
				if ((_v2.a.$ === 'Just') && (_v2.b.$ === 'Just')) {
					var src = _v2.a.a;
					var tgt = _v2.b.a;
					return $author$project$Game$WireAction$MergeStack(
						_Utils_update(
							p,
							{source: src, target: tgt}));
				} else {
					return action;
				}
			case 'MoveStack':
				var p = action.a;
				var _v3 = A2($author$project$Game$Agent$GeometryPlan$findByContent, p.stack, board);
				if (_v3.$ === 'Just') {
					var live = _v3.a;
					return $author$project$Game$WireAction$MoveStack(
						_Utils_update(
							p,
							{stack: live}));
				} else {
					return action;
				}
			default:
				return action;
		}
	});
var $author$project$Game$Agent$GeometryPlan$planOne = F2(
	function (board, action) {
		var resolved = A2($author$project$Game$Agent$GeometryPlan$resolveAction, board, action);
		var postBoard = A2($author$project$Game$Agent$GeometryPlan$applyOnBoard, resolved, board);
		if (A2($author$project$Game$Agent$GeometryPlan$isCleanAfterAction, board, postBoard)) {
			return _Utils_Tuple2(
				_List_fromArray(
					[resolved]),
				postBoard);
		} else {
			var _v0 = A2($author$project$Game$Agent$GeometryPlan$preFlight, board, resolved);
			if (_v0.$ === 'Just') {
				var _v1 = _v0.a;
				var movePrim = _v1.a;
				var newAction = _v1.b;
				var newPostBoard = _v1.c;
				return _Utils_Tuple2(
					_List_fromArray(
						[movePrim, newAction]),
					newPostBoard);
			} else {
				return _Utils_Tuple2(
					_List_fromArray(
						[resolved]),
					postBoard);
			}
		}
	});
var $author$project$Game$Agent$GeometryPlan$planLoop = F3(
	function (board, remaining, acc) {
		planLoop:
		while (true) {
			if (!remaining.b) {
				return $elm$core$List$reverse(acc);
			} else {
				var action = remaining.a;
				var rest = remaining.b;
				var _v1 = A2($author$project$Game$Agent$GeometryPlan$planOne, board, action);
				var emitted = _v1.a;
				var postBoard = _v1.b;
				var $temp$board = postBoard,
					$temp$remaining = rest,
					$temp$acc = _Utils_ap(
					$elm$core$List$reverse(emitted),
					acc);
				board = $temp$board;
				remaining = $temp$remaining;
				acc = $temp$acc;
				continue planLoop;
			}
		}
	});
var $author$project$Game$Agent$GeometryPlan$planActions = F2(
	function (board, actions) {
		return A3($author$project$Game$Agent$GeometryPlan$planLoop, board, actions, _List_Nil);
	});
var $author$project$Main$Msg$ActionSent = function (a) {
	return {$: 'ActionSent', a: a};
};
var $author$project$Game$CardStack$encodeBoardLocation = function (loc) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'top',
				$elm$json$Json$Encode$int(loc.top)),
				_Utils_Tuple2(
				'left',
				$elm$json$Json$Encode$int(loc.left))
			]));
};
var $author$project$Game$Card$encodeCard = function (card) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'value',
				$elm$json$Json$Encode$int(
					$author$project$Game$Card$cardValueToInt(card.value))),
				_Utils_Tuple2(
				'suit',
				$elm$json$Json$Encode$int(
					$author$project$Game$Card$suitToInt(card.suit))),
				_Utils_Tuple2(
				'origin_deck',
				$elm$json$Json$Encode$int(
					$author$project$Game$Card$originDeckToInt(card.originDeck)))
			]));
};
var $author$project$Game$CardStack$boardCardStateToInt = function (s) {
	switch (s.$) {
		case 'FirmlyOnBoard':
			return 0;
		case 'FreshlyPlayed':
			return 1;
		default:
			return 2;
	}
};
var $author$project$Game$CardStack$encodeBoardCard = function (bc) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'card',
				$author$project$Game$Card$encodeCard(bc.card)),
				_Utils_Tuple2(
				'state',
				$elm$json$Json$Encode$int(
					$author$project$Game$CardStack$boardCardStateToInt(bc.state)))
			]));
};
var $elm$json$Json$Encode$list = F2(
	function (func, entries) {
		return _Json_wrap(
			A3(
				$elm$core$List$foldl,
				_Json_addEntry(func),
				_Json_emptyArray(_Utils_Tuple0),
				entries));
	});
var $author$project$Game$CardStack$encodeCardStack = function (stack) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				'board_cards',
				A2($elm$json$Json$Encode$list, $author$project$Game$CardStack$encodeBoardCard, stack.boardCards)),
				_Utils_Tuple2(
				'loc',
				$author$project$Game$CardStack$encodeBoardLocation(stack.loc))
			]));
};
var $author$project$Game$WireAction$encodeSide = function (side) {
	if (side.$ === 'Left') {
		return $elm$json$Json$Encode$string('left');
	} else {
		return $elm$json$Json$Encode$string('right');
	}
};
var $author$project$Game$WireAction$encode = function (action) {
	switch (action.$) {
		case 'Split':
			var p = action.a;
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('split')),
						_Utils_Tuple2(
						'stack',
						$author$project$Game$CardStack$encodeCardStack(p.stack)),
						_Utils_Tuple2(
						'card_index',
						$elm$json$Json$Encode$int(p.cardIndex))
					]));
		case 'MergeStack':
			var p = action.a;
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('merge_stack')),
						_Utils_Tuple2(
						'source',
						$author$project$Game$CardStack$encodeCardStack(p.source)),
						_Utils_Tuple2(
						'target',
						$author$project$Game$CardStack$encodeCardStack(p.target)),
						_Utils_Tuple2(
						'side',
						$author$project$Game$WireAction$encodeSide(p.side))
					]));
		case 'MergeHand':
			var p = action.a;
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('merge_hand')),
						_Utils_Tuple2(
						'hand_card',
						$author$project$Game$Card$encodeCard(p.handCard)),
						_Utils_Tuple2(
						'target',
						$author$project$Game$CardStack$encodeCardStack(p.target)),
						_Utils_Tuple2(
						'side',
						$author$project$Game$WireAction$encodeSide(p.side))
					]));
		case 'PlaceHand':
			var p = action.a;
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('place_hand')),
						_Utils_Tuple2(
						'hand_card',
						$author$project$Game$Card$encodeCard(p.handCard)),
						_Utils_Tuple2(
						'loc',
						$author$project$Game$CardStack$encodeBoardLocation(p.loc))
					]));
		case 'MoveStack':
			var p = action.a;
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('move_stack')),
						_Utils_Tuple2(
						'stack',
						$author$project$Game$CardStack$encodeCardStack(p.stack)),
						_Utils_Tuple2(
						'new_loc',
						$author$project$Game$CardStack$encodeBoardLocation(p.newLoc))
					]));
		case 'CompleteTurn':
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('complete_turn'))
					]));
		default:
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$elm$json$Json$Encode$string('undo'))
					]));
	}
};
var $elm$json$Json$Encode$float = _Json_wrap;
var $author$project$Main$Wire$encodeGesturePoint = function (p) {
	return $elm$json$Json$Encode$object(
		_List_fromArray(
			[
				_Utils_Tuple2(
				't',
				$elm$json$Json$Encode$float(p.tMs)),
				_Utils_Tuple2(
				'x',
				$elm$json$Json$Encode$int(p.x)),
				_Utils_Tuple2(
				'y',
				$elm$json$Json$Encode$int(p.y))
			]));
};
var $author$project$Main$Wire$pathFrameString = function (frame) {
	if (frame.$ === 'BoardFrame') {
		return 'board';
	} else {
		return 'viewport';
	}
};
var $author$project$Main$Wire$encodeEnvelope = F2(
	function (action, maybeGesture) {
		if (maybeGesture.$ === 'Nothing') {
			return $elm$json$Json$Encode$object(
				_List_fromArray(
					[
						_Utils_Tuple2(
						'action',
						$author$project$Game$WireAction$encode(action))
					]));
		} else {
			var path = maybeGesture.a.path;
			var frame = maybeGesture.a.frame;
			if (!path.b) {
				return $elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2(
							'action',
							$author$project$Game$WireAction$encode(action))
						]));
			} else {
				return $elm$json$Json$Encode$object(
					_List_fromArray(
						[
							_Utils_Tuple2(
							'action',
							$author$project$Game$WireAction$encode(action)),
							_Utils_Tuple2(
							'gesture_metadata',
							$elm$json$Json$Encode$object(
								_List_fromArray(
									[
										_Utils_Tuple2(
										'path',
										A2($elm$json$Json$Encode$list, $author$project$Main$Wire$encodeGesturePoint, path)),
										_Utils_Tuple2(
										'path_frame',
										$elm$json$Json$Encode$string(
											$author$project$Main$Wire$pathFrameString(frame))),
										_Utils_Tuple2(
										'pointer_type',
										$elm$json$Json$Encode$string('mouse'))
									])))
						]));
			}
		}
	});
var $author$project$Main$Wire$sendAction = F3(
	function (sessionId, action, maybeGesture) {
		return $elm$http$Http$post(
			{
				body: $elm$http$Http$jsonBody(
					A2($author$project$Main$Wire$encodeEnvelope, action, maybeGesture)),
				expect: $elm$http$Http$expectWhatever($author$project$Main$Msg$ActionSent),
				url: '/gopher/lynrummy-elm/actions?session=' + $elm$core$String$fromInt(sessionId)
			});
	});
var $author$project$Main$Play$sendOneFull = F2(
	function (sid, _v0) {
		var prim = _v0.a;
		var gesture = _v0.b;
		return A3($author$project$Main$Wire$sendAction, sid, prim, gesture);
	});
var $author$project$Main$Wire$sendPuzzleAction = F4(
	function (sessionId, puzzleName, action, maybeGesture) {
		return $elm$http$Http$post(
			{
				body: $elm$http$Http$jsonBody(
					A2($author$project$Main$Wire$encodeEnvelope, action, maybeGesture)),
				expect: $elm$http$Http$expectWhatever($author$project$Main$Msg$ActionSent),
				url: '/gopher/board-lab/actions?session=' + ($elm$core$String$fromInt(sessionId) + ('&puzzle=' + puzzleName))
			});
	});
var $author$project$Main$Play$sendOnePuzzle = F3(
	function (sid, name, _v0) {
		var prim = _v0.a;
		var gesture = _v0.b;
		return A4($author$project$Main$Wire$sendPuzzleAction, sid, name, prim, gesture);
	});
var $author$project$Game$Replay$Space$boardEndpoints = F2(
	function (action, model) {
		switch (action.$) {
			case 'MoveStack':
				var p = action.a;
				return A2(
					$elm$core$Maybe$map,
					function (src) {
						return _Utils_Tuple2(
							{x: src.loc.left, y: src.loc.top},
							{x: p.newLoc.left, y: p.newLoc.top});
					},
					A2($author$project$Game$CardStack$findStack, p.stack, model.board));
			case 'MergeStack':
				var p = action.a;
				return A3(
					$elm$core$Maybe$map2,
					F2(
						function (src, tgt) {
							var tgtSize = $author$project$Game$CardStack$size(tgt);
							var srcSize = $author$project$Game$CardStack$size(src);
							var endLeft = function () {
								var _v1 = p.side;
								if (_v1.$ === 'Right') {
									return tgt.loc.left + (tgtSize * $author$project$Game$BoardGeometry$cardPitch);
								} else {
									return tgt.loc.left - (srcSize * $author$project$Game$BoardGeometry$cardPitch);
								}
							}();
							return _Utils_Tuple2(
								{x: src.loc.left, y: src.loc.top},
								{x: endLeft + 2, y: tgt.loc.top - 2});
						}),
					A2($author$project$Game$CardStack$findStack, p.source, model.board),
					A2($author$project$Game$CardStack$findStack, p.target, model.board));
			default:
				return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$Replay$Space$dragMsPerPixel = 2.5;
var $author$project$Game$Replay$Space$quinticEase = function (f) {
	var f3 = (f * f) * f;
	return f3 * ((f * ((f * 6) - 15)) + 10);
};
var $elm$core$Basics$sqrt = _Basics_sqrt;
var $author$project$Game$Replay$Space$easedPath = F3(
	function (start, end, nowMs) {
		var samples = 20;
		var dy = end.y - start.y;
		var dx = end.x - start.x;
		var dist = $elm$core$Basics$sqrt((dx * dx) + (dy * dy));
		var duration = A2($elm$core$Basics$max, 100, dist * $author$project$Game$Replay$Space$dragMsPerPixel);
		var step = function (i) {
			var frac = i / (samples - 1);
			var pos = $author$project$Game$Replay$Space$quinticEase(frac);
			return {
				tMs: nowMs + (frac * duration),
				x: $elm$core$Basics$round(start.x + (dx * pos)),
				y: $elm$core$Basics$round(start.y + (dy * pos))
			};
		};
		return A2(
			$elm$core$List$map,
			step,
			A2($elm$core$List$range, 0, samples - 1));
	});
var $author$project$Game$Replay$Space$synthesizeBoardPath = F3(
	function (action, model, nowMs) {
		return A2(
			$elm$core$Maybe$map,
			function (_v0) {
				var start = _v0.a;
				var end = _v0.b;
				return _Utils_Tuple2(
					A3($author$project$Game$Replay$Space$easedPath, start, end, nowMs),
					$author$project$Main$State$BoardFrame);
			},
			A2($author$project$Game$Replay$Space$boardEndpoints, action, model));
	});
var $author$project$Main$Play$synthesizeAgentGestures = F2(
	function (initialModel, prims) {
		var loop = F3(
			function (simModel, acc, remaining) {
				loop:
				while (true) {
					if (!remaining.b) {
						return $elm$core$List$reverse(acc);
					} else {
						var p = remaining.a;
						var rest = remaining.b;
						var synth = A2(
							$elm$core$Maybe$map,
							function (_v1) {
								var path = _v1.a;
								var frame = _v1.b;
								return {frame: frame, path: path};
							},
							A3($author$project$Game$Replay$Space$synthesizeBoardPath, p, simModel, 0));
						var nextSim = A2($author$project$Main$Apply$applyAction, p, simModel).model;
						var $temp$simModel = nextSim,
							$temp$acc = A2(
							$elm$core$List$cons,
							_Utils_Tuple2(p, synth),
							acc),
							$temp$remaining = rest;
						simModel = $temp$simModel;
						acc = $temp$acc;
						remaining = $temp$remaining;
						continue loop;
					}
				}
			});
		return A3(loop, initialModel, _List_Nil, prims);
	});
var $author$project$Main$Play$runAgentMove = F3(
	function (move, remaining, model) {
		var primitives = A2(
			$author$project$Game$Agent$GeometryPlan$planActions,
			model.board,
			A2($author$project$Game$Agent$Verbs$moveToPrimitives, model.board, move));
		if ($elm$core$List$isEmpty(primitives)) {
			var described = $author$project$Game$Agent$Move$describe(move);
			var _v0 = A2($elm$core$Debug$log, 'agent: move emitted no primitives', described);
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{
						agentProgram: $elm$core$Maybe$Nothing,
						status: {kind: $author$project$Main$State$Scold, text: 'Agent stalled: couldn\'t emit primitives for ' + (described + ' — see console.')}
					}),
				$elm$core$Platform$Cmd$none);
		} else {
			var primGestures = A2($author$project$Main$Play$synthesizeAgentGestures, model, primitives);
			var wireCmds = function () {
				var _v1 = model.sessionId;
				if (_v1.$ === 'Just') {
					var sid = _v1.a;
					var _v2 = model.puzzleName;
					if (_v2.$ === 'Just') {
						var name = _v2.a;
						return A2(
							$elm$core$List$map,
							A2($author$project$Main$Play$sendOnePuzzle, sid, name),
							primGestures);
					} else {
						return A2(
							$elm$core$List$map,
							$author$project$Main$Play$sendOneFull(sid),
							primGestures);
					}
				} else {
					return _List_Nil;
				}
			}();
			var entries = A2($elm$core$List$map, $author$project$Main$Play$agentLogEntryWith, primGestures);
			var boardRectCmd = A2(
				$elm$core$Task$attempt,
				$author$project$Main$Msg$BoardRectReceived,
				$elm$browser$Browser$Dom$getElement(
					$author$project$Main$State$boardDomIdFor(model.gameId)));
			var appended = _Utils_update(
				model,
				{
					actionLog: _Utils_ap(model.actionLog, entries),
					agentProgram: $elm$core$Maybe$Just(remaining),
					drag: $author$project$Main$State$NotDragging,
					replay: $elm$core$Maybe$Just(
						{paused: false, pending: entries}),
					replayAnim: $author$project$Main$State$NotAnimating,
					status: {
						kind: $author$project$Main$State$Inform,
						text: 'Agent: ' + $author$project$Game$Agent$Move$describe(move)
					}
				});
			return _Utils_Tuple2(
				appended,
				$elm$core$Platform$Cmd$batch(
					A2($elm$core$List$cons, boardRectCmd, wireCmds)));
		}
	});
var $author$project$Main$Play$clickAgentPlay = function (model) {
	if (!_Utils_eq(model.replay, $elm$core$Maybe$Nothing)) {
		return _Utils_Tuple2(
			_Utils_update(
				model,
				{
					status: {kind: $author$project$Main$State$Scold, text: 'Animation in progress — wait for it to finish before clicking again.'}
				}),
			$elm$core$Platform$Cmd$none);
	} else {
		var _v0 = $author$project$Main$Play$nextAgentMove(model);
		if (_v0.$ === 'Just') {
			var _v1 = _v0.a;
			var move = _v1.a;
			var remaining = _v1.b;
			return A3($author$project$Main$Play$runAgentMove, move, remaining, model);
		} else {
			return _Utils_Tuple2(
				$author$project$Main$Play$noteAgentStatus(model),
				$elm$core$Platform$Cmd$none);
		}
	}
};
var $author$project$Main$View$pluralize = F2(
	function (n, word) {
		return $elm$core$String$fromInt(n) + (' ' + (word + ((n === 1) ? '' : 's')));
	});
var $author$project$Main$View$popupFromOutcome = function (_v0) {
	var result = _v0.result;
	var turnScore = _v0.turnScore;
	var cardsDrawn = _v0.cardsDrawn;
	switch (result.$) {
		case 'Failure':
			return {admin: 'Angry Cat', body: 'The board is not clean!\n\n(nor is my litter box)\n\n' + 'Drag stacks back where they belong.'};
		case 'SuccessButNeedsCards':
			return {
				admin: 'Oliver',
				body: 'Sorry you couldn\'t find a move.\n\n' + ('I\'m going back to my nap!\n\n' + ('You scored ' + ($elm$core$String$fromInt(turnScore) + (' points for your turn.\n\n' + ('We have dealt you ' + (A2($author$project$Main$View$pluralize, cardsDrawn, 'more card') + ' for your next turn.'))))))
			};
		case 'SuccessAsVictor':
			return {
				admin: 'Steve',
				body: 'You are the first person to play all their cards!\n\n' + ('That earns you a 1500 point bonus.\n\n' + ('You got ' + ($elm$core$String$fromInt(turnScore) + (' points for this turn.\n\n' + ('We have dealt you ' + (A2($author$project$Main$View$pluralize, cardsDrawn, 'more card') + (' for your next turn.\n\n' + 'Keep winning!')))))))
			};
		case 'SuccessWithHandEmptied':
			return {
				admin: 'Steve',
				body: 'Good job!\n\n' + ('You scored ' + ($elm$core$String$fromInt(turnScore) + (' for this turn!\n\n' + ('We gave you a bonus for emptying your hand.\n\n' + ('We have dealt you ' + (A2($author$project$Main$View$pluralize, cardsDrawn, 'more card') + ' for your next turn.'))))))
			};
		default:
			return {
				admin: 'Steve',
				body: 'The board is growing!\n\n' + ('You receive ' + ($elm$core$String$fromInt(turnScore) + ' points for this turn!'))
			};
	}
};
var $author$project$Main$View$popupForCompleteTurn = function (result) {
	if (result.$ === 'Ok') {
		var outcome = result.a;
		return $elm$core$Maybe$Just(
			$author$project$Main$View$popupFromOutcome(outcome));
	} else {
		return $elm$core$Maybe$Just(
			{admin: 'Angry Cat', body: 'Couldn\'t reach the server to complete your turn.'});
	}
};
var $author$project$Main$Msg$CompleteTurnResponded = function (a) {
	return {$: 'CompleteTurnResponded', a: a};
};
var $author$project$Game$Game$CompleteTurnOutcome = F4(
	function (result, turnScore, cardsDrawn, dealtCards) {
		return {cardsDrawn: cardsDrawn, dealtCards: dealtCards, result: result, turnScore: turnScore};
	});
var $elm$json$Json$Decode$map4 = _Json_map4;
var $author$project$Game$PlayerTurn$Failure = {$: 'Failure'};
var $author$project$Main$Wire$turnResultDecoder = A2(
	$elm$json$Json$Decode$andThen,
	function (s) {
		switch (s) {
			case 'success':
				return $elm$json$Json$Decode$succeed($author$project$Game$PlayerTurn$Success);
			case 'success_but_needs_cards':
				return $elm$json$Json$Decode$succeed($author$project$Game$PlayerTurn$SuccessButNeedsCards);
			case 'success_as_victor':
				return $elm$json$Json$Decode$succeed($author$project$Game$PlayerTurn$SuccessAsVictor);
			case 'success_with_hand_emptied':
				return $elm$json$Json$Decode$succeed($author$project$Game$PlayerTurn$SuccessWithHandEmptied);
			case 'failure':
				return $elm$json$Json$Decode$succeed($author$project$Game$PlayerTurn$Failure);
			default:
				var other = s;
				return $elm$json$Json$Decode$fail('unknown turn_result: ' + other);
		}
	},
	A2($elm$json$Json$Decode$field, 'turn_result', $elm$json$Json$Decode$string));
var $author$project$Main$Wire$completeTurnOutcomeDecoder = A5(
	$elm$json$Json$Decode$map4,
	$author$project$Game$Game$CompleteTurnOutcome,
	$author$project$Main$Wire$turnResultDecoder,
	A2(
		$elm$json$Json$Decode$map,
		$elm$core$Maybe$withDefault(0),
		$elm$json$Json$Decode$maybe(
			A2($elm$json$Json$Decode$field, 'turn_score', $elm$json$Json$Decode$int))),
	A2(
		$elm$json$Json$Decode$map,
		$elm$core$Maybe$withDefault(0),
		$elm$json$Json$Decode$maybe(
			A2($elm$json$Json$Decode$field, 'cards_drawn', $elm$json$Json$Decode$int))),
	A2(
		$elm$json$Json$Decode$map,
		$elm$core$Maybe$withDefault(_List_Nil),
		$elm$json$Json$Decode$maybe(
			A2(
				$elm$json$Json$Decode$field,
				'dealt_cards',
				$elm$json$Json$Decode$list($author$project$Game$Card$cardDecoder)))));
var $author$project$Main$Wire$decodeCompleteTurnResponse = function (response) {
	switch (response.$) {
		case 'BadUrl_':
			var url = response.a;
			return $elm$core$Result$Err(
				$elm$http$Http$BadUrl(url));
		case 'Timeout_':
			return $elm$core$Result$Err($elm$http$Http$Timeout);
		case 'NetworkError_':
			return $elm$core$Result$Err($elm$http$Http$NetworkError);
		case 'BadStatus_':
			var body = response.b;
			var _v1 = A2($elm$json$Json$Decode$decodeString, $author$project$Main$Wire$completeTurnOutcomeDecoder, body);
			if (_v1.$ === 'Ok') {
				var outcome = _v1.a;
				return $elm$core$Result$Ok(outcome);
			} else {
				return $elm$core$Result$Err(
					$elm$http$Http$BadBody(body));
			}
		default:
			var body = response.b;
			var _v2 = A2($elm$json$Json$Decode$decodeString, $author$project$Main$Wire$completeTurnOutcomeDecoder, body);
			if (_v2.$ === 'Ok') {
				var outcome = _v2.a;
				return $elm$core$Result$Ok(outcome);
			} else {
				var decodeErr = _v2.a;
				return $elm$core$Result$Err(
					$elm$http$Http$BadBody(
						$elm$json$Json$Decode$errorToString(decodeErr)));
			}
	}
};
var $author$project$Main$Wire$sendCompleteTurn = function (sessionId) {
	return $elm$http$Http$post(
		{
			body: $elm$http$Http$jsonBody(
				A2($author$project$Main$Wire$encodeEnvelope, $author$project$Game$WireAction$CompleteTurn, $elm$core$Maybe$Nothing)),
			expect: A2($elm$http$Http$expectStringResponse, $author$project$Main$Msg$CompleteTurnResponded, $author$project$Main$Wire$decodeCompleteTurnResponse),
			url: '/gopher/lynrummy-elm/actions?session=' + $elm$core$String$fromInt(sessionId)
		});
};
var $author$project$Main$View$statusForCompleteTurn = function (outcome) {
	if (outcome.$ === 'Ok') {
		var o = outcome.a;
		var _v1 = o.result;
		switch (_v1.$) {
			case 'Success':
				return {kind: $author$project$Main$State$Celebrate, text: 'Turn complete. Board is growing!'};
			case 'SuccessButNeedsCards':
				return {kind: $author$project$Main$State$Inform, text: 'Turn complete, but you didn\'t play any cards.'};
			case 'SuccessAsVictor':
				return {kind: $author$project$Main$State$Celebrate, text: 'Hand emptied — victor!'};
			case 'SuccessWithHandEmptied':
				return {kind: $author$project$Main$State$Celebrate, text: 'Hand emptied — nice.'};
			default:
				return {kind: $author$project$Main$State$Scold, text: 'Board isn\'t clean — tidy up before ending the turn.'};
		}
	} else {
		return {kind: $author$project$Main$State$Scold, text: 'Couldn\'t reach the server to complete the turn.'};
	}
};
var $elm$core$Result$andThen = F2(
	function (callback, result) {
		if (result.$ === 'Ok') {
			var value = result.a;
			return callback(value);
		} else {
			var msg = result.a;
			return $elm$core$Result$Err(msg);
		}
	});
var $author$project$Game$Referee$Geometry = {$: 'Geometry'};
var $author$project$Game$Referee$checkGeometry = F2(
	function (board, bounds) {
		var _v0 = A2($author$project$Game$BoardGeometry$validateBoardGeometry, board, bounds);
		if (!_v0.b) {
			return $elm$core$Result$Ok(_Utils_Tuple0);
		} else {
			var first = _v0.a;
			return $elm$core$Result$Err(
				{message: first.message, stage: $author$project$Game$Referee$Geometry});
		}
	});
var $author$project$Game$Referee$Semantics = {$: 'Semantics'};
var $author$project$Game$Referee$findFirstBadStack = function (board) {
	findFirstBadStack:
	while (true) {
		if (!board.b) {
			return $elm$core$Maybe$Nothing;
		} else {
			var s = board.a;
			var rest = board.b;
			var st = $author$project$Game$StackType$getStackType(
				A2(
					$elm$core$List$map,
					function ($) {
						return $.card;
					},
					s.boardCards));
			switch (st.$) {
				case 'Incomplete':
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(s, st));
				case 'Bogus':
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(s, st));
				case 'Dup':
					return $elm$core$Maybe$Just(
						_Utils_Tuple2(s, st));
				default:
					var $temp$board = rest;
					board = $temp$board;
					continue findFirstBadStack;
			}
		}
	}
};
var $author$project$Game$Card$suitEmojiStr = function (suit) {
	switch (suit.$) {
		case 'Club':
			return '♣';
		case 'Diamond':
			return '♦';
		case 'Heart':
			return '♥';
		default:
			return '♠';
	}
};
var $author$project$Game$Card$cardStr = function (card) {
	return _Utils_ap(
		$author$project$Game$Card$valueStr(card.value),
		$author$project$Game$Card$suitEmojiStr(card.suit));
};
var $author$project$Game$Referee$stackDebugStr = function (s) {
	return A2(
		$elm$core$String$join,
		',',
		A2(
			$elm$core$List$map,
			A2(
				$elm$core$Basics$composeR,
				function ($) {
					return $.card;
				},
				$author$project$Game$Card$cardStr),
			s.boardCards));
};
var $author$project$Game$Referee$stackTypeStr = function (t) {
	switch (t.$) {
		case 'Incomplete':
			return 'incomplete';
		case 'Bogus':
			return 'bogus';
		case 'Dup':
			return 'dup';
		case 'Set':
			return 'set';
		case 'PureRun':
			return 'pure run';
		default:
			return 'red/black alternating';
	}
};
var $author$project$Game$Referee$checkSemantics = function (board) {
	var _v0 = $author$project$Game$Referee$findFirstBadStack(board);
	if (_v0.$ === 'Just') {
		var _v1 = _v0.a;
		var stack = _v1.a;
		var badType = _v1.b;
		return $elm$core$Result$Err(
			{
				message: 'stack \"' + ($author$project$Game$Referee$stackDebugStr(stack) + ('\" is ' + $author$project$Game$Referee$stackTypeStr(badType))),
				stage: $author$project$Game$Referee$Semantics
			});
	} else {
		return $elm$core$Result$Ok(_Utils_Tuple0);
	}
};
var $author$project$Game$Referee$validateTurnComplete = F2(
	function (board, bounds) {
		return A2(
			$elm$core$Result$andThen,
			function (_v0) {
				return $author$project$Game$Referee$checkSemantics(board);
			},
			A2($author$project$Game$Referee$checkGeometry, board, bounds));
	});
var $author$project$Main$Play$clickCompleteTurn = function (model) {
	var _v0 = A2($author$project$Game$Referee$validateTurnComplete, model.board, $author$project$Main$Apply$refereeBounds);
	if (_v0.$ === 'Err') {
		var refErr = _v0.a;
		return _Utils_Tuple2(
			_Utils_update(
				model,
				{
					status: {kind: $author$project$Main$State$Scold, text: 'Board isn\'t clean: ' + refErr.message}
				}),
			$elm$core$Platform$Cmd$none);
	} else {
		var persistCmd = function () {
			var _v2 = model.sessionId;
			if (_v2.$ === 'Just') {
				var sid = _v2.a;
				return $author$project$Main$Wire$sendCompleteTurn(sid);
			} else {
				return $elm$core$Platform$Cmd$none;
			}
		}();
		var completeTurnEntry = {action: $author$project$Game$WireAction$CompleteTurn, gesturePath: $elm$core$Maybe$Nothing, pathFrame: $author$project$Main$State$ViewportFrame};
		var withEntry = _Utils_update(
			model,
			{
				actionLog: _Utils_ap(
					model.actionLog,
					_List_fromArray(
						[completeTurnEntry]))
			});
		var _v1 = $author$project$Game$Game$applyCompleteTurn(withEntry);
		var afterTurn = _v1.a;
		var turnOutcome = _v1.b;
		var newModel = _Utils_update(
			afterTurn,
			{
				popup: $author$project$Main$View$popupForCompleteTurn(
					$elm$core$Result$Ok(turnOutcome)),
				score: $author$project$Game$Score$forStacks(afterTurn.board),
				status: $author$project$Main$View$statusForCompleteTurn(
					$elm$core$Result$Ok(turnOutcome))
			});
		return _Utils_Tuple2(newModel, persistCmd);
	}
};
var $author$project$Main$Play$bfsHint = function (model) {
	var _v0 = $author$project$Game$Agent$Bfs$solveBoard(model.board);
	if (_v0.$ === 'Just') {
		if (_v0.a.b) {
			var _v1 = _v0.a;
			var firstMove = _v1.a;
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{
						hintedCards: _List_Nil,
						status: {
							kind: $author$project$Main$State$Inform,
							text: 'Hint: ' + $author$project$Game$Agent$Move$describe(firstMove)
						}
					}),
				$elm$core$Platform$Cmd$none);
		} else {
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{
						hintedCards: _List_Nil,
						status: {kind: $author$project$Main$State$Inform, text: 'Board is already clean — nothing to do.'}
					}),
				$elm$core$Platform$Cmd$none);
		}
	} else {
		return _Utils_Tuple2(
			_Utils_update(
				model,
				{
					hintedCards: _List_Nil,
					status: {kind: $author$project$Main$State$Inform, text: 'BFS found no plan within budget.'}
				}),
			$elm$core$Platform$Cmd$none);
	}
};
var $author$project$Game$Strategy$Hint$firstPlayAsSuggestion = F3(
	function (handCards, board, _v0) {
		var i = _v0.a;
		var trick = _v0.b;
		var _v1 = A2(trick.findPlays, handCards, board);
		if (!_v1.b) {
			return $elm$core$Maybe$Nothing;
		} else {
			var first = _v1.a;
			return $elm$core$Maybe$Just(
				{
					description: trick.description,
					handCards: A2(
						$elm$core$List$map,
						function ($) {
							return $.card;
						},
						first.handCards),
					rank: i + 1,
					trickId: trick.id
				});
		}
	});
var $author$project$Game$Strategy$Helpers$dummyLoc = {left: 0, top: 0};
var $author$project$Game$Strategy$DirectPlay$mergeEitherSide = F2(
	function (target, single) {
		var _v0 = A2($author$project$Game$CardStack$rightMerge, target, single);
		if (_v0.$ === 'Just') {
			var m = _v0.a;
			return $elm$core$Maybe$Just(m);
		} else {
			return A2($author$project$Game$CardStack$leftMerge, target, single);
		}
	});
var $author$project$Game$Strategy$Helpers$replaceAt = F3(
	function (idx, x, list) {
		return A2(
			$elm$core$List$indexedMap,
			F2(
				function (i, y) {
					return _Utils_eq(i, idx) ? x : y;
				}),
			list);
	});
var $author$project$Game$Strategy$DirectPlay$applyDirectPlay = F3(
	function (hc, targetIdx, board) {
		var single = A2($author$project$Game$CardStack$fromHandCard, hc, $author$project$Game$Strategy$Helpers$dummyLoc);
		var _v0 = $elm$core$List$head(
			A2($elm$core$List$drop, targetIdx, board));
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(board, _List_Nil);
		} else {
			var targetStack = _v0.a;
			var _v1 = A2($author$project$Game$Strategy$DirectPlay$mergeEitherSide, targetStack, single);
			if (_v1.$ === 'Just') {
				var merged = _v1.a;
				return _Utils_Tuple2(
					A3($author$project$Game$Strategy$Helpers$replaceAt, targetIdx, merged, board),
					_List_fromArray(
						[hc]));
			} else {
				return _Utils_Tuple2(board, _List_Nil);
			}
		}
	});
var $author$project$Game$Strategy$DirectPlay$makePlay = F2(
	function (hc, targetIdx) {
		return {
			apply: A2($author$project$Game$Strategy$DirectPlay$applyDirectPlay, hc, targetIdx),
			handCards: _List_fromArray(
				[hc]),
			trickId: 'direct_play'
		};
	});
var $author$project$Game$Strategy$DirectPlay$findPlaysForHandCard = F2(
	function (hc, board) {
		var single = A2($author$project$Game$CardStack$fromHandCard, hc, $author$project$Game$Strategy$Helpers$dummyLoc);
		return A2(
			$elm$core$List$filterMap,
			function (_v0) {
				var idx = _v0.a;
				var stack = _v0.b;
				var _v1 = A2($author$project$Game$CardStack$rightMerge, stack, single);
				if (_v1.$ === 'Just') {
					return $elm$core$Maybe$Just(
						A2($author$project$Game$Strategy$DirectPlay$makePlay, hc, idx));
				} else {
					var _v2 = A2($author$project$Game$CardStack$leftMerge, stack, single);
					if (_v2.$ === 'Just') {
						return $elm$core$Maybe$Just(
							A2($author$project$Game$Strategy$DirectPlay$makePlay, hc, idx));
					} else {
						return $elm$core$Maybe$Nothing;
					}
				}
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$DirectPlay$findPlays = F2(
	function (hand, board) {
		return A2(
			$elm$core$List$concatMap,
			function (hc) {
				return A2($author$project$Game$Strategy$DirectPlay$findPlaysForHandCard, hc, board);
			},
			hand);
	});
var $author$project$Game$Strategy$DirectPlay$trick = {description: 'Play a hand card onto the end of a stack.', findPlays: $author$project$Game$Strategy$DirectPlay$findPlays, id: 'direct_play'};
var $author$project$Game$Strategy$HandStacks$groupBySuit = function (hand) {
	return A3(
		$elm$core$List$foldr,
		F2(
			function (hc, acc) {
				var k = $author$project$Game$Card$suitToInt(hc.card.suit);
				return A3(
					$elm$core$Dict$update,
					k,
					function (cur) {
						if (cur.$ === 'Nothing') {
							return $elm$core$Maybe$Just(
								_List_fromArray(
									[hc]));
						} else {
							var existing = cur.a;
							return $elm$core$Maybe$Just(
								A2($elm$core$List$cons, hc, existing));
						}
					},
					acc);
			}),
		$elm$core$Dict$empty,
		hand);
};
var $author$project$Game$Strategy$HandStacks$isValidGroup = function (cards) {
	var _v0 = $author$project$Game$StackType$getStackType(
		A2(
			$elm$core$List$map,
			function ($) {
				return $.card;
			},
			cards));
	switch (_v0.$) {
		case 'Set':
			return true;
		case 'PureRun':
			return true;
		case 'RedBlackRun':
			return true;
		default:
			return false;
	}
};
var $author$project$Game$Strategy$HandStacks$consecutiveRuns = function (sorted) {
	var _v0 = A3(
		$elm$core$List$foldl,
		F2(
			function (hc, _v1) {
				var acc = _v1.a;
				var current = _v1.b;
				if (!current.b) {
					return _Utils_Tuple2(
						acc,
						_List_fromArray(
							[hc]));
				} else {
					var prev = current.a;
					return _Utils_eq(
						$author$project$Game$Card$cardValueToInt(hc.card.value),
						$author$project$Game$Card$cardValueToInt(prev.card.value) + 1) ? _Utils_Tuple2(
						acc,
						A2($elm$core$List$cons, hc, current)) : ((($elm$core$List$length(current) >= 3) && $author$project$Game$Strategy$HandStacks$isValidGroup(
						$elm$core$List$reverse(current))) ? _Utils_Tuple2(
						A2(
							$elm$core$List$cons,
							$elm$core$List$reverse(current),
							acc),
						_List_fromArray(
							[hc])) : _Utils_Tuple2(
						acc,
						_List_fromArray(
							[hc])));
				}
			}),
		_Utils_Tuple2(_List_Nil, _List_Nil),
		sorted);
	var runs = _v0.a;
	var _final = _v0.b;
	return $elm$core$List$reverse(
		(($elm$core$List$length(_final) >= 3) && $author$project$Game$Strategy$HandStacks$isValidGroup(
			$elm$core$List$reverse(_final))) ? A2(
			$elm$core$List$cons,
			$elm$core$List$reverse(_final),
			runs) : runs);
};
var $elm$core$Tuple$second = function (_v0) {
	var y = _v0.b;
	return y;
};
var $author$project$Game$Strategy$HandStacks$dedupeByValue = function (cards) {
	return A3(
		$elm$core$List$foldr,
		F2(
			function (hc, _v0) {
				var seen = _v0.a;
				var acc = _v0.b;
				var k = $author$project$Game$Card$cardValueToInt(hc.card.value);
				return A2($elm$core$List$member, k, seen) ? _Utils_Tuple2(seen, acc) : _Utils_Tuple2(
					A2($elm$core$List$cons, k, seen),
					A2($elm$core$List$cons, hc, acc));
			}),
		_Utils_Tuple2(_List_Nil, _List_Nil),
		cards).b;
};
var $author$project$Game$Strategy$HandStacks$longestPureRuns = function (cards) {
	var sorted = A2(
		$elm$core$List$sortBy,
		A2(
			$elm$core$Basics$composeR,
			function ($) {
				return $.card;
			},
			A2(
				$elm$core$Basics$composeR,
				function ($) {
					return $.value;
				},
				$author$project$Game$Card$cardValueToInt)),
		$author$project$Game$Strategy$HandStacks$dedupeByValue(cards));
	return $author$project$Game$Strategy$HandStacks$consecutiveRuns(sorted);
};
var $author$project$Game$Strategy$HandStacks$findPureRuns = function (hand) {
	return A2(
		$elm$core$List$concatMap,
		function (_v0) {
			var cards = _v0.b;
			return A2(
				$elm$core$List$filter,
				function (run) {
					return $elm$core$List$length(run) >= 3;
				},
				$author$project$Game$Strategy$HandStacks$longestPureRuns(cards));
		},
		$elm$core$Dict$toList(
			$author$project$Game$Strategy$HandStacks$groupBySuit(hand)));
};
var $author$project$Game$Strategy$HandStacks$rbConsecutiveRuns = function (sorted) {
	var _v0 = A3(
		$elm$core$List$foldl,
		F2(
			function (hc, _v1) {
				var acc = _v1.a;
				var current = _v1.b;
				if (!current.b) {
					return _Utils_Tuple2(
						acc,
						_List_fromArray(
							[hc]));
				} else {
					var prev = current.a;
					var valOK = _Utils_eq(
						$author$project$Game$Card$cardValueToInt(hc.card.value),
						$author$project$Game$Card$cardValueToInt(prev.card.value) + 1);
					var colorOK = !_Utils_eq(
						$author$project$Game$Card$suitColor(hc.card.suit),
						$author$project$Game$Card$suitColor(prev.card.suit));
					return (valOK && colorOK) ? _Utils_Tuple2(
						acc,
						A2($elm$core$List$cons, hc, current)) : ((($elm$core$List$length(current) >= 3) && $author$project$Game$Strategy$HandStacks$isValidGroup(
						$elm$core$List$reverse(current))) ? _Utils_Tuple2(
						A2(
							$elm$core$List$cons,
							$elm$core$List$reverse(current),
							acc),
						_List_fromArray(
							[hc])) : _Utils_Tuple2(
						acc,
						_List_fromArray(
							[hc])));
				}
			}),
		_Utils_Tuple2(_List_Nil, _List_Nil),
		sorted);
	var runs = _v0.a;
	var _final = _v0.b;
	return $elm$core$List$reverse(
		(($elm$core$List$length(_final) >= 3) && $author$project$Game$Strategy$HandStacks$isValidGroup(
			$elm$core$List$reverse(_final))) ? A2(
			$elm$core$List$cons,
			$elm$core$List$reverse(_final),
			runs) : runs);
};
var $author$project$Game$Strategy$HandStacks$findRbRuns = function (hand) {
	var sorted = A2(
		$elm$core$List$sortBy,
		A2(
			$elm$core$Basics$composeR,
			function ($) {
				return $.card;
			},
			A2(
				$elm$core$Basics$composeR,
				function ($) {
					return $.value;
				},
				$author$project$Game$Card$cardValueToInt)),
		$author$project$Game$Strategy$HandStacks$dedupeByValue(hand));
	return A2(
		$elm$core$List$filter,
		function (run) {
			return $elm$core$List$length(run) >= 3;
		},
		$author$project$Game$Strategy$HandStacks$rbConsecutiveRuns(sorted));
};
var $author$project$Game$Strategy$HandStacks$groupByValue = function (hand) {
	return A3(
		$elm$core$List$foldr,
		F2(
			function (hc, acc) {
				var k = $author$project$Game$Card$cardValueToInt(hc.card.value);
				return A3(
					$elm$core$Dict$update,
					k,
					function (cur) {
						if (cur.$ === 'Nothing') {
							return $elm$core$Maybe$Just(
								_List_fromArray(
									[hc]));
						} else {
							var existing = cur.a;
							return $elm$core$Maybe$Just(
								A2($elm$core$List$cons, hc, existing));
						}
					},
					acc);
			}),
		$elm$core$Dict$empty,
		hand);
};
var $author$project$Game$Strategy$HandStacks$pickValidSet = function (cards) {
	var chosen = A3(
		$elm$core$List$foldr,
		F2(
			function (hc, _v0) {
				var seen = _v0.a;
				var acc = _v0.b;
				var s = $author$project$Game$Card$suitToInt(hc.card.suit);
				return A2($elm$core$List$member, s, seen) ? _Utils_Tuple2(seen, acc) : _Utils_Tuple2(
					A2($elm$core$List$cons, s, seen),
					A2($elm$core$List$cons, hc, acc));
			}),
		_Utils_Tuple2(_List_Nil, _List_Nil),
		cards).b;
	return ($elm$core$List$length(chosen) < 3) ? $elm$core$Maybe$Nothing : (_Utils_eq(
		$author$project$Game$StackType$getStackType(
			A2(
				$elm$core$List$map,
				function ($) {
					return $.card;
				},
				chosen)),
		$author$project$Game$StackType$Set) ? $elm$core$Maybe$Just(chosen) : $elm$core$Maybe$Nothing);
};
var $author$project$Game$Strategy$HandStacks$findSets = function (hand) {
	return A2(
		$elm$core$List$filterMap,
		function (_v0) {
			var cards = _v0.b;
			return ($elm$core$List$length(cards) < 3) ? $elm$core$Maybe$Nothing : $author$project$Game$Strategy$HandStacks$pickValidSet(cards);
		},
		$elm$core$Dict$toList(
			$author$project$Game$Strategy$HandStacks$groupByValue(hand)));
};
var $author$project$Game$Strategy$HandStacks$findCandidateGroups = function (hand) {
	return _Utils_ap(
		$author$project$Game$Strategy$HandStacks$findSets(hand),
		_Utils_ap(
			$author$project$Game$Strategy$HandStacks$findPureRuns(hand),
			$author$project$Game$Strategy$HandStacks$findRbRuns(hand)));
};
var $author$project$Game$Strategy$Helpers$freshlyPlayed = function (hc) {
	return {card: hc.card, state: $author$project$Game$CardStack$FreshlyPlayed};
};
var $author$project$Game$Strategy$Helpers$pushNewStack = F2(
	function (board, boardCards) {
		return _Utils_ap(
			board,
			_List_fromArray(
				[
					{boardCards: boardCards, loc: $author$project$Game$Strategy$Helpers$dummyLoc}
				]));
	});
var $author$project$Game$Strategy$HandStacks$applyHandStacks = F2(
	function (group, board) {
		return $author$project$Game$Strategy$HandStacks$isValidGroup(group) ? _Utils_Tuple2(
			A2(
				$author$project$Game$Strategy$Helpers$pushNewStack,
				board,
				A2($elm$core$List$map, $author$project$Game$Strategy$Helpers$freshlyPlayed, group)),
			group) : _Utils_Tuple2(board, _List_Nil);
	});
var $author$project$Game$Strategy$HandStacks$makePlay = function (group) {
	return {
		apply: $author$project$Game$Strategy$HandStacks$applyHandStacks(group),
		handCards: group,
		trickId: 'hand_stacks'
	};
};
var $author$project$Game$Strategy$HandStacks$findPlays = F2(
	function (hand, _v0) {
		return A2(
			$elm$core$List$map,
			$author$project$Game$Strategy$HandStacks$makePlay,
			$author$project$Game$Strategy$HandStacks$findCandidateGroups(hand));
	});
var $author$project$Game$Strategy$HandStacks$trick = {description: 'You already have 3+ cards in your hand that form a set or run!', findPlays: $author$project$Game$Strategy$HandStacks$findPlays, id: 'hand_stacks'};
var $author$project$Game$Strategy$Helpers$singleStackFromCard = function (c) {
	return A2(
		$author$project$Game$CardStack$fromHandCard,
		{card: c, state: $author$project$Game$CardStack$HandNormal},
		$author$project$Game$Strategy$Helpers$dummyLoc);
};
var $author$project$Game$Strategy$LooseCardPlay$cardExtendsAnyStack = F2(
	function (card, board) {
		var single = $author$project$Game$Strategy$Helpers$singleStackFromCard(card);
		return A2(
			$elm$core$List$any,
			function (s) {
				var _v0 = A2($author$project$Game$CardStack$leftMerge, s, single);
				if (_v0.$ === 'Just') {
					return true;
				} else {
					var _v1 = A2($author$project$Game$CardStack$rightMerge, s, single);
					if (_v1.$ === 'Just') {
						return true;
					} else {
						return false;
					}
				}
			},
			board);
	});
var $author$project$Game$CardStack$canExtract = F2(
	function (stack, cardIdx) {
		var st = $author$project$Game$CardStack$stackType(stack);
		var n = $author$project$Game$CardStack$size(stack);
		return _Utils_eq(st, $author$project$Game$StackType$Set) ? (n >= 4) : (((!_Utils_eq(st, $author$project$Game$StackType$PureRun)) && (!_Utils_eq(st, $author$project$Game$StackType$RedBlackRun))) ? false : (((n >= 4) && ((!cardIdx) || _Utils_eq(cardIdx, n - 1))) ? true : (((cardIdx >= 3) && (((n - cardIdx) - 1) >= 3)) ? true : false)));
	});
var $author$project$Game$Strategy$LooseCardPlay$firstBoardCard = function (stack) {
	return A2(
		$elm$core$Maybe$map,
		function ($) {
			return $.card;
		},
		$elm$core$List$head(stack.boardCards));
};
var $author$project$Game$Strategy$Helpers$extractCard = F3(
	function (board, stackIdx, cardIdx) {
		var _v0 = $elm$core$List$head(
			A2($elm$core$List$drop, stackIdx, board));
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(board, $elm$core$Maybe$Nothing);
		} else {
			var stack = _v0.a;
			var st = $author$project$Game$CardStack$stackType(stack);
			var isRun = _Utils_eq(st, $author$project$Game$StackType$PureRun) || _Utils_eq(st, $author$project$Game$StackType$RedBlackRun);
			var cards = stack.boardCards;
			var n = $elm$core$List$length(cards);
			if ((!cardIdx) && (n >= 4)) {
				var newStack = {
					boardCards: A2($elm$core$List$drop, 1, cards),
					loc: stack.loc
				};
				return _Utils_Tuple2(
					A3($author$project$Game$Strategy$Helpers$replaceAt, stackIdx, newStack, board),
					$elm$core$List$head(cards));
			} else {
				if (_Utils_eq(cardIdx, n - 1) && (n >= 4)) {
					var newStack = {
						boardCards: A2($elm$core$List$take, n - 1, cards),
						loc: stack.loc
					};
					return _Utils_Tuple2(
						A3($author$project$Game$Strategy$Helpers$replaceAt, stackIdx, newStack, board),
						$elm$core$List$head(
							A2($elm$core$List$drop, n - 1, cards)));
				} else {
					if (_Utils_eq(st, $author$project$Game$StackType$Set) && (n >= 4)) {
						var remaining = _Utils_ap(
							A2($elm$core$List$take, cardIdx, cards),
							A2($elm$core$List$drop, cardIdx + 1, cards));
						var newStack = {boardCards: remaining, loc: stack.loc};
						var extracted = $elm$core$List$head(
							A2($elm$core$List$drop, cardIdx, cards));
						return _Utils_Tuple2(
							A3($author$project$Game$Strategy$Helpers$replaceAt, stackIdx, newStack, board),
							extracted);
					} else {
						if (isRun && ((cardIdx >= 3) && (((n - cardIdx) - 1) >= 3))) {
							var rightHalf = {
								boardCards: A2($elm$core$List$drop, cardIdx + 1, cards),
								loc: $author$project$Game$Strategy$Helpers$dummyLoc
							};
							var leftHalf = {
								boardCards: A2($elm$core$List$take, cardIdx, cards),
								loc: stack.loc
							};
							var newBoard = _Utils_ap(
								A3($author$project$Game$Strategy$Helpers$replaceAt, stackIdx, leftHalf, board),
								_List_fromArray(
									[rightHalf]));
							var extracted = $elm$core$List$head(
								A2($elm$core$List$drop, cardIdx, cards));
							return _Utils_Tuple2(newBoard, extracted);
						} else {
							return _Utils_Tuple2(board, $elm$core$Maybe$Nothing);
						}
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$LooseCardPlay$markFreshlyPlayedFor = F2(
	function (hc, board) {
		return A2(
			$elm$core$List$map,
			function (stack) {
				return {
					boardCards: A2(
						$elm$core$List$map,
						function (bc) {
							return (_Utils_eq(bc.card.value, hc.card.value) && (_Utils_eq(bc.card.suit, hc.card.suit) && _Utils_eq(bc.card.originDeck, hc.card.originDeck))) ? $author$project$Game$Strategy$Helpers$freshlyPlayed(hc) : bc;
						},
						stack.boardCards),
					loc: stack.loc
				};
			},
			board);
	});
var $author$project$Game$Strategy$LooseCardPlay$mergeEitherSide = F2(
	function (target, single) {
		var _v0 = A2($author$project$Game$CardStack$leftMerge, target, single);
		if (_v0.$ === 'Just') {
			var m = _v0.a;
			return $elm$core$Maybe$Just(m);
		} else {
			return A2($author$project$Game$CardStack$rightMerge, target, single);
		}
	});
var $author$project$Game$Strategy$LooseCardPlay$mergedIsProblematic = function (s) {
	var t = $author$project$Game$CardStack$stackType(s);
	return _Utils_eq(t, $author$project$Game$StackType$Bogus) || (_Utils_eq(t, $author$project$Game$StackType$Dup) || _Utils_eq(t, $author$project$Game$StackType$Incomplete));
};
var $author$project$Game$Strategy$LooseCardPlay$playHandCardOnBoard = F2(
	function (hc, board) {
		var handSingle = $author$project$Game$Strategy$Helpers$singleStackFromCard(hc.card);
		var go = F2(
			function (i, stacks) {
				go:
				while (true) {
					if (!stacks.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var s = stacks.a;
						var rest = stacks.b;
						var _v1 = A2($author$project$Game$CardStack$rightMerge, s, handSingle);
						if (_v1.$ === 'Just') {
							var ext = _v1.a;
							return $elm$core$Maybe$Just(
								A3($author$project$Game$Strategy$Helpers$replaceAt, i, ext, board));
						} else {
							var _v2 = A2($author$project$Game$CardStack$leftMerge, s, handSingle);
							if (_v2.$ === 'Just') {
								var ext = _v2.a;
								return $elm$core$Maybe$Just(
									A3($author$project$Game$Strategy$Helpers$replaceAt, i, ext, board));
							} else {
								var $temp$i = i + 1,
									$temp$stacks = rest;
								i = $temp$i;
								stacks = $temp$stacks;
								continue go;
							}
						}
					}
				}
			});
		return A2(go, 0, board);
	});
var $author$project$Game$Strategy$LooseCardPlay$findInStack = F2(
	function (stack, target) {
		var go = F2(
			function (ci, cards) {
				go:
				while (true) {
					if (!cards.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var bc = cards.a;
						var rest = cards.b;
						if (_Utils_eq(bc.card.value, target.value) && (_Utils_eq(bc.card.suit, target.suit) && (_Utils_eq(bc.card.originDeck, target.originDeck) && A2($author$project$Game$CardStack$canExtract, stack, ci)))) {
							return $elm$core$Maybe$Just(ci);
						} else {
							var $temp$ci = ci + 1,
								$temp$cards = rest;
							ci = $temp$ci;
							cards = $temp$cards;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, stack.boardCards);
	});
var $author$project$Game$Strategy$LooseCardPlay$relocate = F2(
	function (board, target) {
		var go = F2(
			function (si, stacks) {
				go:
				while (true) {
					if (!stacks.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var stack = stacks.a;
						var rest = stacks.b;
						var _v1 = A2($author$project$Game$Strategy$LooseCardPlay$findInStack, stack, target);
						if (_v1.$ === 'Just') {
							var ci = _v1.a;
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(si, ci));
						} else {
							var $temp$si = si + 1,
								$temp$stacks = rest;
							si = $temp$si;
							stacks = $temp$stacks;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, board);
	});
var $author$project$Game$Strategy$LooseCardPlay$relocateStack = F2(
	function (board, anchor) {
		var go = F2(
			function (si, stacks) {
				go:
				while (true) {
					if (!stacks.b) {
						return -1;
					} else {
						var stack = stacks.a;
						var rest = stacks.b;
						var _v1 = $elm$core$List$head(stack.boardCards);
						if (_v1.$ === 'Just') {
							var firstCard = _v1.a;
							if (_Utils_eq(firstCard.card.value, anchor.value) && (_Utils_eq(firstCard.card.suit, anchor.suit) && _Utils_eq(firstCard.card.originDeck, anchor.originDeck))) {
								return si;
							} else {
								var $temp$si = si + 1,
									$temp$stacks = rest;
								si = $temp$si;
								stacks = $temp$stacks;
								continue go;
							}
						} else {
							var $temp$si = si + 1,
								$temp$stacks = rest;
							si = $temp$si;
							stacks = $temp$stacks;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, board);
	});
var $author$project$Game$Strategy$LooseCardPlay$applyLooseCardPlay = F2(
	function (m, board) {
		var _v0 = A2($author$project$Game$Strategy$LooseCardPlay$relocate, board, m.srcCard);
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(board, _List_Nil);
		} else {
			var _v1 = _v0.a;
			var srcSi = _v1.a;
			var srcCi = _v1.b;
			var destIdx = A2($author$project$Game$Strategy$LooseCardPlay$relocateStack, board, m.destCard);
			if ((destIdx < 0) || _Utils_eq(destIdx, srcSi)) {
				return _Utils_Tuple2(board, _List_Nil);
			} else {
				var _v2 = A3($author$project$Game$Strategy$Helpers$extractCard, board, srcSi, srcCi);
				var board2 = _v2.a;
				var maybePeeled = _v2.b;
				if (maybePeeled.$ === 'Nothing') {
					return _Utils_Tuple2(board, _List_Nil);
				} else {
					var peeled = maybePeeled.a;
					var destIdxAfter = A2($author$project$Game$Strategy$LooseCardPlay$relocateStack, board2, m.destCard);
					if (destIdxAfter < 0) {
						return _Utils_Tuple2(board, _List_Nil);
					} else {
						var _v4 = $elm$core$List$head(
							A2($elm$core$List$drop, destIdxAfter, board2));
						if (_v4.$ === 'Nothing') {
							return _Utils_Tuple2(board, _List_Nil);
						} else {
							var destStack = _v4.a;
							var single = $author$project$Game$Strategy$Helpers$singleStackFromCard(peeled.card);
							var _v5 = A2($author$project$Game$Strategy$LooseCardPlay$mergeEitherSide, destStack, single);
							if (_v5.$ === 'Nothing') {
								return _Utils_Tuple2(board, _List_Nil);
							} else {
								var merged = _v5.a;
								if ($author$project$Game$Strategy$LooseCardPlay$mergedIsProblematic(merged)) {
									return _Utils_Tuple2(board, _List_Nil);
								} else {
									var board3 = A3($author$project$Game$Strategy$Helpers$replaceAt, destIdxAfter, merged, board2);
									var _v6 = A2($author$project$Game$Strategy$LooseCardPlay$playHandCardOnBoard, m.handCard, board3);
									if (_v6.$ === 'Just') {
										var board4 = _v6.a;
										return _Utils_Tuple2(
											A2($author$project$Game$Strategy$LooseCardPlay$markFreshlyPlayedFor, m.handCard, board4),
											_List_fromArray(
												[m.handCard]));
									} else {
										return _Utils_Tuple2(board, _List_Nil);
									}
								}
							}
						}
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$LooseCardPlay$makePlay = function (m) {
	return {
		apply: $author$project$Game$Strategy$LooseCardPlay$applyLooseCardPlay(m),
		handCards: _List_fromArray(
			[m.handCard]),
		trickId: 'loose_card_play'
	};
};
var $author$project$Game$Strategy$LooseCardPlay$peelIntoResidual = F2(
	function (stack, cardIdx) {
		var st = $author$project$Game$CardStack$stackType(stack);
		var isRun = _Utils_eq(st, $author$project$Game$StackType$PureRun) || _Utils_eq(st, $author$project$Game$StackType$RedBlackRun);
		var cards = stack.boardCards;
		var n = $elm$core$List$length(cards);
		return ((!cardIdx) && (n >= 4)) ? $elm$core$Maybe$Just(
			{
				boardCards: A2($elm$core$List$drop, 1, cards),
				loc: stack.loc
			}) : ((_Utils_eq(cardIdx, n - 1) && (n >= 4)) ? $elm$core$Maybe$Just(
			{
				boardCards: A2($elm$core$List$take, n - 1, cards),
				loc: stack.loc
			}) : ((_Utils_eq(st, $author$project$Game$StackType$Set) && (n >= 4)) ? $elm$core$Maybe$Just(
			{
				boardCards: _Utils_ap(
					A2($elm$core$List$take, cardIdx, cards),
					A2($elm$core$List$drop, cardIdx + 1, cards)),
				loc: stack.loc
			}) : ((isRun && ((cardIdx >= 3) && (((n - cardIdx) - 1) >= 3))) ? $elm$core$Maybe$Just(
			{
				boardCards: A2($elm$core$List$take, cardIdx, cards),
				loc: stack.loc
			}) : $elm$core$Maybe$Nothing)));
	});
var $author$project$Game$Strategy$LooseCardPlay$simulateMove = F6(
	function (board, src, ci, dest, merged, srcStack) {
		var _v0 = A2($author$project$Game$Strategy$LooseCardPlay$peelIntoResidual, srcStack, ci);
		if (_v0.$ === 'Nothing') {
			return $elm$core$Maybe$Nothing;
		} else {
			var residual = _v0.a;
			return $elm$core$Maybe$Just(
				A3(
					$author$project$Game$Strategy$Helpers$replaceAt,
					dest,
					merged,
					A3($author$project$Game$Strategy$Helpers$replaceAt, src, residual, board)));
		}
	});
var $author$project$Game$Strategy$LooseCardPlay$tryDestinations = F6(
	function (board, stranded, src, srcStack, ci, peeled) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var dest = _v0.a;
				var destStack = _v0.b;
				if (_Utils_eq(dest, src)) {
					return _List_Nil;
				} else {
					var _v1 = $author$project$Game$Strategy$LooseCardPlay$firstBoardCard(destStack);
					if (_v1.$ === 'Nothing') {
						return _List_Nil;
					} else {
						var destAnchor = _v1.a;
						var single = $author$project$Game$Strategy$Helpers$singleStackFromCard(peeled);
						var _v2 = A2($author$project$Game$Strategy$LooseCardPlay$mergeEitherSide, destStack, single);
						if (_v2.$ === 'Nothing') {
							return _List_Nil;
						} else {
							var merged = _v2.a;
							if ($author$project$Game$Strategy$LooseCardPlay$mergedIsProblematic(merged)) {
								return _List_Nil;
							} else {
								var _v3 = A6($author$project$Game$Strategy$LooseCardPlay$simulateMove, board, src, ci, dest, merged, srcStack);
								if (_v3.$ === 'Nothing') {
									return _List_Nil;
								} else {
									var sim = _v3.a;
									return A2(
										$elm$core$List$filterMap,
										function (hc) {
											return A2($author$project$Game$Strategy$LooseCardPlay$cardExtendsAnyStack, hc.card, sim) ? $elm$core$Maybe$Just(
												$author$project$Game$Strategy$LooseCardPlay$makePlay(
													{destCard: destAnchor, destIdx: dest, handCard: hc, srcCard: peeled, srcCardIdx: ci, srcIdx: src})) : $elm$core$Maybe$Nothing;
										},
										stranded);
								}
							}
						}
					}
				}
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$LooseCardPlay$findMoves = F2(
	function (board, stranded) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var src = _v0.a;
				var srcStack = _v0.b;
				return A2(
					$elm$core$List$concatMap,
					function (_v1) {
						var ci = _v1.a;
						var bc = _v1.b;
						return (!A2($author$project$Game$CardStack$canExtract, srcStack, ci)) ? _List_Nil : A6($author$project$Game$Strategy$LooseCardPlay$tryDestinations, board, stranded, src, srcStack, ci, bc.card);
					},
					A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, srcStack.boardCards));
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$LooseCardPlay$findPlays = F2(
	function (hand, board) {
		var stranded = A2(
			$elm$core$List$filter,
			function (hc) {
				return !A2($author$project$Game$Strategy$LooseCardPlay$cardExtendsAnyStack, hc.card, board);
			},
			hand);
		return $elm$core$List$isEmpty(stranded) ? _List_Nil : A2($author$project$Game$Strategy$LooseCardPlay$findMoves, board, stranded);
	});
var $author$project$Game$Strategy$LooseCardPlay$trick = {description: 'Move one board card to a new home, then play a hand card on the resulting board.', findPlays: $author$project$Game$Strategy$LooseCardPlay$findPlays, id: 'loose_card_play'};
var $author$project$Game$Strategy$PairPeel$cardsEqual = F2(
	function (a, b) {
		return _Utils_eq(a.value, b.value) && (_Utils_eq(a.suit, b.suit) && _Utils_eq(a.originDeck, b.originDeck));
	});
var $author$project$Game$Strategy$PairPeel$handPairs = function (hand) {
	return A2(
		$elm$core$List$concatMap,
		function (_v0) {
			var i = _v0.a;
			var a = _v0.b;
			return A2(
				$elm$core$List$filterMap,
				function (_v1) {
					var j = _v1.a;
					var b = _v1.b;
					return ((_Utils_cmp(j, i) > 0) && (!A2($author$project$Game$Strategy$PairPeel$cardsEqual, a.card, b.card))) ? $elm$core$Maybe$Just(
						_Utils_Tuple2(a, b)) : $elm$core$Maybe$Nothing;
				},
				A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, hand));
		},
		A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, hand));
};
var $author$project$Game$Strategy$PairPeel$applyPairPeel = F6(
	function (hca, hcb, si, ci, peelTarget, board) {
		var _v0 = $elm$core$List$head(
			A2($elm$core$List$drop, si, board));
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(board, _List_Nil);
		} else {
			var stack = _v0.a;
			var _v1 = $elm$core$List$head(
				A2($elm$core$List$drop, ci, stack.boardCards));
			if (_v1.$ === 'Nothing') {
				return _Utils_Tuple2(board, _List_Nil);
			} else {
				var bc = _v1.a;
				if (!A2($author$project$Game$Strategy$PairPeel$cardsEqual, bc.card, peelTarget)) {
					return _Utils_Tuple2(board, _List_Nil);
				} else {
					if (!A2($author$project$Game$CardStack$canExtract, stack, ci)) {
						return _Utils_Tuple2(board, _List_Nil);
					} else {
						var _v2 = A3($author$project$Game$Strategy$Helpers$extractCard, board, si, ci);
						var board2 = _v2.a;
						var maybeExt = _v2.b;
						if (maybeExt.$ === 'Nothing') {
							return _Utils_Tuple2(board, _List_Nil);
						} else {
							var extracted = maybeExt.a;
							var group = A2(
								$elm$core$List$sortBy,
								A2(
									$elm$core$Basics$composeR,
									function ($) {
										return $.card;
									},
									A2(
										$elm$core$Basics$composeR,
										function ($) {
											return $.value;
										},
										$author$project$Game$Card$cardValueToInt)),
								_List_fromArray(
									[
										$author$project$Game$Strategy$Helpers$freshlyPlayed(hca),
										$author$project$Game$Strategy$Helpers$freshlyPlayed(hcb),
										extracted
									]));
							var newStack = {boardCards: group, loc: $author$project$Game$Strategy$Helpers$dummyLoc};
							var resultType = $author$project$Game$StackType$getStackType(
								A2(
									$elm$core$List$map,
									function ($) {
										return $.card;
									},
									group));
							return (_Utils_eq(resultType, $author$project$Game$StackType$Bogus) || (_Utils_eq(resultType, $author$project$Game$StackType$Dup) || _Utils_eq(resultType, $author$project$Game$StackType$Incomplete))) ? _Utils_Tuple2(board, _List_Nil) : _Utils_Tuple2(
								_Utils_ap(
									board2,
									_List_fromArray(
										[newStack])),
								_List_fromArray(
									[hca, hcb]));
						}
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$PairPeel$makePlay = F5(
	function (hca, hcb, si, ci, targetCard) {
		return {
			apply: A5($author$project$Game$Strategy$PairPeel$applyPairPeel, hca, hcb, si, ci, targetCard),
			handCards: _List_fromArray(
				[hca, hcb]),
			trickId: 'pair_peel'
		};
	});
var $author$project$Game$Strategy$PairPeel$oppositeColorSuits = function (c) {
	return _Utils_eq(c, $author$project$Game$Card$Red) ? _List_fromArray(
		[$author$project$Game$Card$Spade, $author$project$Game$Card$Club]) : _List_fromArray(
		[$author$project$Game$Card$Heart, $author$project$Game$Card$Diamond]);
};
var $author$project$Game$Strategy$PairPeel$pairNeeds = F2(
	function (a, b) {
		if (_Utils_eq(a.value, b.value) && (!_Utils_eq(a.suit, b.suit))) {
			var allSuits = _List_fromArray(
				[$author$project$Game$Card$Heart, $author$project$Game$Card$Spade, $author$project$Game$Card$Diamond, $author$project$Game$Card$Club]);
			var rem = A2(
				$elm$core$List$filter,
				function (s) {
					return (!_Utils_eq(s, a.suit)) && (!_Utils_eq(s, b.suit));
				},
				allSuits);
			return _List_fromArray(
				[
					{suits: rem, value: a.value}
				]);
		} else {
			var _v0 = (_Utils_cmp(
				$author$project$Game$Card$cardValueToInt(a.value),
				$author$project$Game$Card$cardValueToInt(b.value)) < 0) ? _Utils_Tuple2(a, b) : _Utils_Tuple2(b, a);
			var lo = _v0.a;
			var hi = _v0.b;
			if (!_Utils_eq(
				hi.value,
				$author$project$Game$StackType$successor(lo.value))) {
				return _List_Nil;
			} else {
				if (_Utils_eq(a.suit, b.suit)) {
					return _List_fromArray(
						[
							{
							suits: _List_fromArray(
								[lo.suit]),
							value: $author$project$Game$StackType$predecessor(lo.value)
						},
							{
							suits: _List_fromArray(
								[hi.suit]),
							value: $author$project$Game$StackType$successor(hi.value)
						}
						]);
				} else {
					if (!_Utils_eq(
						$author$project$Game$Card$suitColor(a.suit),
						$author$project$Game$Card$suitColor(b.suit))) {
						var oppLo = $author$project$Game$Strategy$PairPeel$oppositeColorSuits(
							$author$project$Game$Card$suitColor(lo.suit));
						var oppHi = $author$project$Game$Strategy$PairPeel$oppositeColorSuits(
							$author$project$Game$Card$suitColor(hi.suit));
						return _List_fromArray(
							[
								{
								suits: oppLo,
								value: $author$project$Game$StackType$predecessor(lo.value)
							},
								{
								suits: oppHi,
								value: $author$project$Game$StackType$successor(hi.value)
							}
							]);
					} else {
						return _List_Nil;
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$PairPeel$scanBoardForNeed = F2(
	function (board, need) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var si = _v0.a;
				var stack = _v0.b;
				return A2(
					$elm$core$List$filterMap,
					function (_v1) {
						var ci = _v1.a;
						var bc = _v1.b;
						return (_Utils_eq(bc.card.value, need.value) && (A2($elm$core$List$member, bc.card.suit, need.suits) && A2($author$project$Game$CardStack$canExtract, stack, ci))) ? $elm$core$Maybe$Just(
							_Utils_Tuple3(si, ci, bc.card)) : $elm$core$Maybe$Nothing;
					},
					A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, stack.boardCards));
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$PairPeel$findPlays = F2(
	function (hand, board) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var hca = _v0.a;
				var hcb = _v0.b;
				return A2(
					$elm$core$List$concatMap,
					function (need) {
						return A2(
							$elm$core$List$map,
							function (_v1) {
								var si = _v1.a;
								var ci = _v1.b;
								var targetCard = _v1.c;
								return A5($author$project$Game$Strategy$PairPeel$makePlay, hca, hcb, si, ci, targetCard);
							},
							A2($author$project$Game$Strategy$PairPeel$scanBoardForNeed, board, need));
					},
					A2($author$project$Game$Strategy$PairPeel$pairNeeds, hca.card, hcb.card));
			},
			$author$project$Game$Strategy$PairPeel$handPairs(hand));
	});
var $author$project$Game$Strategy$PairPeel$trick = {description: 'Peel a board card to complete a pair in your hand.', findPlays: $author$project$Game$Strategy$PairPeel$findPlays, id: 'pair_peel'};
var $author$project$Game$Strategy$PeelForRun$cardsEqual = F2(
	function (a, b) {
		return _Utils_eq(a.value, b.value) && (_Utils_eq(a.suit, b.suit) && _Utils_eq(a.originDeck, b.originDeck));
	});
var $author$project$Game$Strategy$PeelForRun$findPeelableAtValue = F3(
	function (board, value, exclude) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var si = _v0.a;
				var stack = _v0.b;
				return A2(
					$elm$core$List$filterMap,
					function (_v1) {
						var ci = _v1.a;
						var bc = _v1.b;
						return (_Utils_eq(bc.card.value, value) && ((!A2($author$project$Game$Strategy$PeelForRun$cardsEqual, bc.card, exclude)) && A2($author$project$Game$CardStack$canExtract, stack, ci))) ? $elm$core$Maybe$Just(
							{card: bc.card, cardIdx: ci, stackIdx: si}) : $elm$core$Maybe$Nothing;
					},
					A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, stack.boardCards));
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$PeelForRun$findInStack = F2(
	function (stack, target) {
		var go = F2(
			function (ci, cards) {
				go:
				while (true) {
					if (!cards.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var bc = cards.a;
						var rest = cards.b;
						if (A2($author$project$Game$Strategy$PeelForRun$cardsEqual, bc.card, target) && A2($author$project$Game$CardStack$canExtract, stack, ci)) {
							return $elm$core$Maybe$Just(ci);
						} else {
							var $temp$ci = ci + 1,
								$temp$cards = rest;
							ci = $temp$ci;
							cards = $temp$cards;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, stack.boardCards);
	});
var $author$project$Game$Strategy$PeelForRun$relocate = F2(
	function (board, target) {
		var go = F2(
			function (si, stacks) {
				go:
				while (true) {
					if (!stacks.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var stack = stacks.a;
						var rest = stacks.b;
						var _v1 = A2($author$project$Game$Strategy$PeelForRun$findInStack, stack, target);
						if (_v1.$ === 'Just') {
							var ci = _v1.a;
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(si, ci));
						} else {
							var $temp$si = si + 1,
								$temp$stacks = rest;
							si = $temp$si;
							stacks = $temp$stacks;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, board);
	});
var $author$project$Game$Strategy$PeelForRun$applyPeelForRun = F4(
	function (hc, targetPrev, targetNext, board) {
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Strategy$PeelForRun$relocate, board, targetPrev),
			A2($author$project$Game$Strategy$PeelForRun$relocate, board, targetNext));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var _v1 = _v0.a.a;
			var siPrev = _v1.a;
			var ciPrev = _v1.b;
			var _v2 = _v0.b.a;
			var siNext = _v2.a;
			var ciNext = _v2.b;
			if (_Utils_eq(siPrev, siNext)) {
				return _Utils_Tuple2(board, _List_Nil);
			} else {
				var extractPrevFirst = (_Utils_cmp(siPrev, siNext) > 0) || (_Utils_eq(siPrev, siNext) && (_Utils_cmp(ciPrev, ciNext) > 0));
				var _v3 = extractPrevFirst ? _Utils_Tuple3(siPrev, ciPrev, targetNext) : _Utils_Tuple3(siNext, ciNext, targetPrev);
				var firstSi = _v3.a;
				var firstCi = _v3.b;
				var secondTarget = _v3.c;
				var _v4 = A3($author$project$Game$Strategy$Helpers$extractCard, board, firstSi, firstCi);
				var board2 = _v4.a;
				var maybeExt0 = _v4.b;
				if (maybeExt0.$ === 'Nothing') {
					return _Utils_Tuple2(board, _List_Nil);
				} else {
					var ext0 = maybeExt0.a;
					var _v6 = A2($author$project$Game$Strategy$PeelForRun$relocate, board2, secondTarget);
					if (_v6.$ === 'Nothing') {
						return _Utils_Tuple2(board, _List_Nil);
					} else {
						var _v7 = _v6.a;
						var secondSi = _v7.a;
						var secondCi = _v7.b;
						var _v8 = A3($author$project$Game$Strategy$Helpers$extractCard, board2, secondSi, secondCi);
						var board3 = _v8.a;
						var maybeExt1 = _v8.b;
						if (maybeExt1.$ === 'Nothing') {
							return _Utils_Tuple2(board, _List_Nil);
						} else {
							var ext1 = maybeExt1.a;
							var trio = A2(
								$elm$core$List$sortBy,
								A2(
									$elm$core$Basics$composeR,
									function ($) {
										return $.card;
									},
									A2(
										$elm$core$Basics$composeR,
										function ($) {
											return $.value;
										},
										$author$project$Game$Card$cardValueToInt)),
								_List_fromArray(
									[
										$author$project$Game$Strategy$Helpers$freshlyPlayed(hc),
										ext0,
										ext1
									]));
							return _Utils_Tuple2(
								A2($author$project$Game$Strategy$Helpers$pushNewStack, board3, trio),
								_List_fromArray(
									[hc]));
						}
					}
				}
			}
		} else {
			return _Utils_Tuple2(board, _List_Nil);
		}
	});
var $author$project$Game$Strategy$PeelForRun$makePlay = F3(
	function (hc, targetPrev, targetNext) {
		return {
			apply: A3($author$project$Game$Strategy$PeelForRun$applyPeelForRun, hc, targetPrev, targetNext),
			handCards: _List_fromArray(
				[hc]),
			trickId: 'peel_for_run'
		};
	});
var $author$project$Game$Strategy$PeelForRun$findPlaysForHandCard = F2(
	function (hc, board) {
		var prevV = $author$project$Game$StackType$predecessor(hc.card.value);
		var prevs = A3($author$project$Game$Strategy$PeelForRun$findPeelableAtValue, board, prevV, hc.card);
		var nextV = $author$project$Game$StackType$successor(hc.card.value);
		var nexts = A3($author$project$Game$Strategy$PeelForRun$findPeelableAtValue, board, nextV, hc.card);
		return A2(
			$elm$core$List$concatMap,
			function (p) {
				return A2(
					$elm$core$List$filterMap,
					function (n) {
						if (_Utils_eq(p.stackIdx, n.stackIdx)) {
							return $elm$core$Maybe$Nothing;
						} else {
							var trio = _List_fromArray(
								[p.card, hc.card, n.card]);
							var t = $author$project$Game$StackType$getStackType(trio);
							return (_Utils_eq(t, $author$project$Game$StackType$PureRun) || _Utils_eq(t, $author$project$Game$StackType$RedBlackRun)) ? $elm$core$Maybe$Just(
								A3($author$project$Game$Strategy$PeelForRun$makePlay, hc, p.card, n.card)) : $elm$core$Maybe$Nothing;
						}
					},
					nexts);
			},
			prevs);
	});
var $author$project$Game$Strategy$PeelForRun$findPlays = F2(
	function (hand, board) {
		return A2(
			$elm$core$List$concatMap,
			function (hc) {
				return A2($author$project$Game$Strategy$PeelForRun$findPlaysForHandCard, hc, board);
			},
			hand);
	});
var $author$project$Game$Strategy$PeelForRun$trick = {description: 'Peel two adjacent-value board cards to form a new run with your hand card.', findPlays: $author$project$Game$Strategy$PeelForRun$findPlays, id: 'peel_for_run'};
var $author$project$Game$Strategy$RbSwap$homeAccepts = F2(
	function (target, kicked) {
		var tst = $author$project$Game$CardStack$stackType(target);
		if (_Utils_eq(tst, $author$project$Game$StackType$Set) && ($elm$core$List$length(target.boardCards) < 4)) {
			var _v0 = $elm$core$List$head(target.boardCards);
			if (_v0.$ === 'Just') {
				var firstCard = _v0.a;
				if (_Utils_eq(firstCard.card.value, kicked.value)) {
					var hasSuit = A2(
						$elm$core$List$any,
						function (bc) {
							return _Utils_eq(bc.card.suit, kicked.suit);
						},
						target.boardCards);
					return !hasSuit;
				} else {
					return false;
				}
			} else {
				return false;
			}
		} else {
			if (_Utils_eq(tst, $author$project$Game$StackType$PureRun)) {
				var single = $author$project$Game$Strategy$Helpers$singleStackFromCard(kicked);
				var _v1 = A2($author$project$Game$CardStack$leftMerge, target, single);
				if (_v1.$ === 'Just') {
					return true;
				} else {
					var _v2 = A2($author$project$Game$CardStack$rightMerge, target, single);
					if (_v2.$ === 'Just') {
						return true;
					} else {
						return false;
					}
				}
			} else {
				return false;
			}
		}
	});
var $author$project$Game$Strategy$RbSwap$findKickedHome = F3(
	function (board, skip, kicked) {
		var go = F2(
			function (j, stacks) {
				go:
				while (true) {
					if (!stacks.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var target = stacks.a;
						var rest = stacks.b;
						if (_Utils_eq(j, skip)) {
							var $temp$j = j + 1,
								$temp$stacks = rest;
							j = $temp$j;
							stacks = $temp$stacks;
							continue go;
						} else {
							if (A2($author$project$Game$Strategy$RbSwap$homeAccepts, target, kicked)) {
								return $elm$core$Maybe$Just(j);
							} else {
								var $temp$j = j + 1,
									$temp$stacks = rest;
								j = $temp$j;
								stacks = $temp$stacks;
								continue go;
							}
						}
					}
				}
			});
		return A2(go, 0, board);
	});
var $author$project$Game$Strategy$RbSwap$listGet = F2(
	function (idx, list) {
		return $elm$core$List$head(
			A2($elm$core$List$drop, idx, list));
	});
var $author$project$Game$Strategy$RbSwap$placeKicked = F3(
	function (board, destIdx, kicked) {
		var _v0 = A2($author$project$Game$Strategy$RbSwap$listGet, destIdx, board);
		if (_v0.$ === 'Nothing') {
			return $elm$core$Maybe$Nothing;
		} else {
			var dest = _v0.a;
			if (_Utils_eq(
				$author$project$Game$CardStack$stackType(dest),
				$author$project$Game$StackType$Set)) {
				var newCards = _Utils_ap(
					dest.boardCards,
					_List_fromArray(
						[
							{card: kicked, state: $author$project$Game$CardStack$FirmlyOnBoard}
						]));
				var newStack = {boardCards: newCards, loc: dest.loc};
				return $elm$core$Maybe$Just(
					A3($author$project$Game$Strategy$Helpers$replaceAt, destIdx, newStack, board));
			} else {
				var single = $author$project$Game$Strategy$Helpers$singleStackFromCard(kicked);
				var _v1 = A2($author$project$Game$CardStack$leftMerge, dest, single);
				if (_v1.$ === 'Just') {
					var merged = _v1.a;
					return $elm$core$Maybe$Just(
						A3($author$project$Game$Strategy$Helpers$replaceAt, destIdx, merged, board));
				} else {
					var _v2 = A2($author$project$Game$CardStack$rightMerge, dest, single);
					if (_v2.$ === 'Just') {
						var merged = _v2.a;
						return $elm$core$Maybe$Just(
							A3($author$project$Game$Strategy$Helpers$replaceAt, destIdx, merged, board));
					} else {
						return $elm$core$Maybe$Nothing;
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$Helpers$substituteInStack = F3(
	function (stack, position, newCard) {
		var updated = A2(
			$elm$core$List$indexedMap,
			F2(
				function (i, bc) {
					return _Utils_eq(i, position) ? newCard : bc;
				}),
			stack.boardCards);
		return {boardCards: updated, loc: stack.loc};
	});
var $author$project$Game$Strategy$RbSwap$applyRbSwap = F6(
	function (hc, runIdx, runPos, kicked, homeIdx, board) {
		var _v0 = _Utils_Tuple2(
			A2($author$project$Game$Strategy$RbSwap$listGet, runIdx, board),
			A2($author$project$Game$Strategy$RbSwap$listGet, homeIdx, board));
		if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
			var runStack = _v0.a.a;
			if (!_Utils_eq(
				$author$project$Game$CardStack$stackType(runStack),
				$author$project$Game$StackType$RedBlackRun)) {
				return _Utils_Tuple2(board, _List_Nil);
			} else {
				var _v1 = $elm$core$List$head(
					A2($elm$core$List$drop, runPos, runStack.boardCards));
				if (_v1.$ === 'Nothing') {
					return _Utils_Tuple2(board, _List_Nil);
				} else {
					var current = _v1.a;
					if (_Utils_eq(current.card.value, kicked.value) && (_Utils_eq(current.card.suit, kicked.suit) && _Utils_eq(current.card.originDeck, kicked.originDeck))) {
						var substituted = A3(
							$author$project$Game$Strategy$Helpers$substituteInStack,
							runStack,
							runPos,
							$author$project$Game$Strategy$Helpers$freshlyPlayed(hc));
						var board2 = A3($author$project$Game$Strategy$Helpers$replaceAt, runIdx, substituted, board);
						var _v2 = A3($author$project$Game$Strategy$RbSwap$placeKicked, board2, homeIdx, kicked);
						if (_v2.$ === 'Just') {
							var board3 = _v2.a;
							return _Utils_Tuple2(
								board3,
								_List_fromArray(
									[hc]));
						} else {
							return _Utils_Tuple2(board, _List_Nil);
						}
					} else {
						return _Utils_Tuple2(board, _List_Nil);
					}
				}
			}
		} else {
			return _Utils_Tuple2(board, _List_Nil);
		}
	});
var $author$project$Game$Strategy$RbSwap$makePlay = F5(
	function (hc, runIdx, runPos, kicked, homeIdx) {
		return {
			apply: A5($author$project$Game$Strategy$RbSwap$applyRbSwap, hc, runIdx, runPos, kicked, homeIdx),
			handCards: _List_fromArray(
				[hc]),
			trickId: 'rb_swap'
		};
	});
var $author$project$Game$Strategy$RbSwap$findSeats = F4(
	function (hc, si, stack, board) {
		var handColor = $author$project$Game$Card$suitColor(hc.card.suit);
		var cards = A2(
			$elm$core$List$map,
			function ($) {
				return $.card;
			},
			stack.boardCards);
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var ci = _v0.a;
				var bc = _v0.b;
				if (_Utils_eq(bc.value, hc.card.value) && (_Utils_eq(
					$author$project$Game$Card$suitColor(bc.suit),
					handColor) && (!_Utils_eq(bc.suit, hc.card.suit)))) {
					var swapped = A2(
						$elm$core$List$indexedMap,
						F2(
							function (i, c) {
								return _Utils_eq(i, ci) ? hc.card : c;
							}),
						cards);
					if (_Utils_eq(
						$author$project$Game$StackType$getStackType(swapped),
						$author$project$Game$StackType$RedBlackRun)) {
						var _v1 = A3($author$project$Game$Strategy$RbSwap$findKickedHome, board, si, bc);
						if (_v1.$ === 'Just') {
							var homeIdx = _v1.a;
							return _List_fromArray(
								[
									A5($author$project$Game$Strategy$RbSwap$makePlay, hc, si, ci, bc, homeIdx)
								]);
						} else {
							return _List_Nil;
						}
					} else {
						return _List_Nil;
					}
				} else {
					return _List_Nil;
				}
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, cards));
	});
var $author$project$Game$Strategy$RbSwap$findPlaysForHandCard = F2(
	function (hc, board) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var si = _v0.a;
				var stack = _v0.b;
				return (!_Utils_eq(
					$author$project$Game$CardStack$stackType(stack),
					$author$project$Game$StackType$RedBlackRun)) ? _List_Nil : A4($author$project$Game$Strategy$RbSwap$findSeats, hc, si, stack, board);
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$RbSwap$findPlays = F2(
	function (hand, board) {
		return A2(
			$elm$core$List$concatMap,
			function (hc) {
				return A2($author$project$Game$Strategy$RbSwap$findPlaysForHandCard, hc, board);
			},
			hand);
	});
var $author$project$Game$Strategy$RbSwap$trick = {description: 'Substitute your card for a same-color one in an rb run; the kicked card goes to a set or pure run.', findPlays: $author$project$Game$Strategy$RbSwap$findPlays, id: 'rb_swap'};
var $author$project$Game$Strategy$SplitForSet$findExtractableSameValue = F2(
	function (target, board) {
		return A2(
			$elm$core$List$concatMap,
			function (_v0) {
				var si = _v0.a;
				var stack = _v0.b;
				return A2(
					$elm$core$List$filterMap,
					function (_v1) {
						var ci = _v1.a;
						var bc = _v1.b;
						return (_Utils_eq(bc.card.value, target.value) && ((!_Utils_eq(bc.card.suit, target.suit)) && A2($author$project$Game$CardStack$canExtract, stack, ci))) ? $elm$core$Maybe$Just(
							{card: bc.card, cardIdx: ci, stackIdx: si}) : $elm$core$Maybe$Nothing;
					},
					A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, stack.boardCards));
			},
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, board));
	});
var $author$project$Game$Strategy$SplitForSet$findInStack = F2(
	function (stack, target) {
		var go = F2(
			function (ci, cards) {
				go:
				while (true) {
					if (!cards.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var bc = cards.a;
						var rest = cards.b;
						if (_Utils_eq(bc.card.value, target.value) && (_Utils_eq(bc.card.suit, target.suit) && (_Utils_eq(bc.card.originDeck, target.originDeck) && A2($author$project$Game$CardStack$canExtract, stack, ci)))) {
							return $elm$core$Maybe$Just(ci);
						} else {
							var $temp$ci = ci + 1,
								$temp$cards = rest;
							ci = $temp$ci;
							cards = $temp$cards;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, stack.boardCards);
	});
var $author$project$Game$Strategy$SplitForSet$relocate = F2(
	function (board, target) {
		var go = F2(
			function (si, stacks) {
				go:
				while (true) {
					if (!stacks.b) {
						return $elm$core$Maybe$Nothing;
					} else {
						var stack = stacks.a;
						var rest = stacks.b;
						var _v1 = A2($author$project$Game$Strategy$SplitForSet$findInStack, stack, target);
						if (_v1.$ === 'Just') {
							var ci = _v1.a;
							return $elm$core$Maybe$Just(
								_Utils_Tuple2(si, ci));
						} else {
							var $temp$si = si + 1,
								$temp$stacks = rest;
							si = $temp$si;
							stacks = $temp$stacks;
							continue go;
						}
					}
				}
			});
		return A2(go, 0, board);
	});
var $author$project$Game$Strategy$SplitForSet$applySplitForSet = F4(
	function (hc, targetA, targetB, board) {
		var _v0 = A2($author$project$Game$Strategy$SplitForSet$relocate, board, targetA);
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(board, _List_Nil);
		} else {
			var _v1 = _v0.a;
			var siA = _v1.a;
			var ciA = _v1.b;
			var _v2 = A3($author$project$Game$Strategy$Helpers$extractCard, board, siA, ciA);
			var board2 = _v2.a;
			var maybeExtA = _v2.b;
			if (maybeExtA.$ === 'Nothing') {
				return _Utils_Tuple2(board, _List_Nil);
			} else {
				var extA = maybeExtA.a;
				var _v4 = A2($author$project$Game$Strategy$SplitForSet$relocate, board2, targetB);
				if (_v4.$ === 'Nothing') {
					return _Utils_Tuple2(board, _List_Nil);
				} else {
					var _v5 = _v4.a;
					var siB = _v5.a;
					var ciB = _v5.b;
					var _v6 = A3($author$project$Game$Strategy$Helpers$extractCard, board2, siB, ciB);
					var board3 = _v6.a;
					var maybeExtB = _v6.b;
					if (maybeExtB.$ === 'Nothing') {
						return _Utils_Tuple2(board, _List_Nil);
					} else {
						var extB = maybeExtB.a;
						return _Utils_Tuple2(
							A2(
								$author$project$Game$Strategy$Helpers$pushNewStack,
								board3,
								_List_fromArray(
									[
										$author$project$Game$Strategy$Helpers$freshlyPlayed(hc),
										extA,
										extB
									])),
							_List_fromArray(
								[hc]));
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$SplitForSet$makePlay = F3(
	function (hc, targetA, targetB) {
		return {
			apply: A3($author$project$Game$Strategy$SplitForSet$applySplitForSet, hc, targetA, targetB),
			handCards: _List_fromArray(
				[hc]),
			trickId: 'split_for_set'
		};
	});
var $author$project$Game$Strategy$SplitForSet$findPartner = F3(
	function (first, candidates, handSuit) {
		findPartner:
		while (true) {
			if (!candidates.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var c = candidates.a;
				var rest = candidates.b;
				if (_Utils_eq(c.card.suit, first.card.suit)) {
					var $temp$first = first,
						$temp$candidates = rest,
						$temp$handSuit = handSuit;
					first = $temp$first;
					candidates = $temp$candidates;
					handSuit = $temp$handSuit;
					continue findPartner;
				} else {
					if (_Utils_eq(c.card.suit, handSuit)) {
						var $temp$first = first,
							$temp$candidates = rest,
							$temp$handSuit = handSuit;
						first = $temp$first;
						candidates = $temp$candidates;
						handSuit = $temp$handSuit;
						continue findPartner;
					} else {
						return $elm$core$Maybe$Just(c);
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$SplitForSet$pickTwoDistinctSuits = F2(
	function (cands, handSuit) {
		pickTwoDistinctSuits:
		while (true) {
			if (!cands.b) {
				return $elm$core$Maybe$Nothing;
			} else {
				var first = cands.a;
				var rest = cands.b;
				if (_Utils_eq(first.card.suit, handSuit)) {
					var $temp$cands = rest,
						$temp$handSuit = handSuit;
					cands = $temp$cands;
					handSuit = $temp$handSuit;
					continue pickTwoDistinctSuits;
				} else {
					var _v1 = A3($author$project$Game$Strategy$SplitForSet$findPartner, first, rest, handSuit);
					if (_v1.$ === 'Just') {
						var partner = _v1.a;
						return $elm$core$Maybe$Just(
							_Utils_Tuple2(first, partner));
					} else {
						var $temp$cands = rest,
							$temp$handSuit = handSuit;
						cands = $temp$cands;
						handSuit = $temp$handSuit;
						continue pickTwoDistinctSuits;
					}
				}
			}
		}
	});
var $author$project$Game$Strategy$SplitForSet$findPlaysForHandCard = F2(
	function (hc, board) {
		var cands = A2($author$project$Game$Strategy$SplitForSet$findExtractableSameValue, hc.card, board);
		if ($elm$core$List$length(cands) < 2) {
			return _List_Nil;
		} else {
			var _v0 = A2($author$project$Game$Strategy$SplitForSet$pickTwoDistinctSuits, cands, hc.card.suit);
			if (_v0.$ === 'Nothing') {
				return _List_Nil;
			} else {
				var _v1 = _v0.a;
				var a = _v1.a;
				var b = _v1.b;
				var trio = _List_fromArray(
					[hc.card, a.card, b.card]);
				return _Utils_eq(
					$author$project$Game$StackType$getStackType(trio),
					$author$project$Game$StackType$Set) ? _List_fromArray(
					[
						A3($author$project$Game$Strategy$SplitForSet$makePlay, hc, a.card, b.card)
					]) : _List_Nil;
			}
		}
	});
var $author$project$Game$Strategy$SplitForSet$findPlays = F2(
	function (hand, board) {
		return A2(
			$elm$core$List$concatMap,
			function (hc) {
				return A2($author$project$Game$Strategy$SplitForSet$findPlaysForHandCard, hc, board);
			},
			hand);
	});
var $author$project$Game$Strategy$SplitForSet$trick = {description: 'Take two same-value cards out of the board and form a new set with your hand card.', findPlays: $author$project$Game$Strategy$SplitForSet$findPlays, id: 'split_for_set'};
var $author$project$Game$Strategy$Hint$hintPriorityOrder = _List_fromArray(
	[$author$project$Game$Strategy$DirectPlay$trick, $author$project$Game$Strategy$HandStacks$trick, $author$project$Game$Strategy$PairPeel$trick, $author$project$Game$Strategy$SplitForSet$trick, $author$project$Game$Strategy$PeelForRun$trick, $author$project$Game$Strategy$RbSwap$trick, $author$project$Game$Strategy$LooseCardPlay$trick]);
var $author$project$Game$Strategy$Hint$buildSuggestions = F2(
	function (hand, board) {
		return A2(
			$elm$core$List$filterMap,
			A2($author$project$Game$Strategy$Hint$firstPlayAsSuggestion, hand.handCards, board),
			A2($elm$core$List$indexedMap, $elm$core$Tuple$pair, $author$project$Game$Strategy$Hint$hintPriorityOrder));
	});
var $author$project$Main$Play$handHint = function (model) {
	var suggestions = A2(
		$author$project$Game$Strategy$Hint$buildSuggestions,
		$author$project$Main$State$activeHand(model),
		model.board);
	if (suggestions.b) {
		var first = suggestions.a;
		return _Utils_Tuple2(
			_Utils_update(
				model,
				{
					hintedCards: first.handCards,
					status: {kind: $author$project$Main$State$Inform, text: first.description}
				}),
			$elm$core$Platform$Cmd$none);
	} else {
		return _Utils_Tuple2(
			_Utils_update(
				model,
				{
					hintedCards: _List_Nil,
					status: {kind: $author$project$Main$State$Inform, text: 'No hint — no obvious play for this hand on this board.'}
				}),
			$elm$core$Platform$Cmd$none);
	}
};
var $author$project$Main$Play$clickHint = function (model) {
	return model.hideTurnControls ? $author$project$Main$Play$bfsHint(model) : $author$project$Main$Play$handHint(model);
};
var $author$project$Main$State$PreRoll = function (a) {
	return {$: 'PreRoll', a: a};
};
var $author$project$Game$Replay$Time$clickInstantReplay = function (model) {
	var _v0 = model.replayBaseline;
	if (_v0.$ === 'Nothing') {
		return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
	} else {
		var baseline = _v0.a;
		var rewound = _Utils_update(
			model,
			{
				activePlayerIndex: baseline.activePlayerIndex,
				board: baseline.board,
				cardsPlayedThisTurn: baseline.cardsPlayedThisTurn,
				deck: baseline.deck,
				hands: baseline.hands,
				score: $author$project$Game$Score$forStacks(baseline.board),
				scores: baseline.scores,
				turnIndex: baseline.turnIndex,
				turnStartBoardScore: baseline.turnStartBoardScore,
				victorAwarded: baseline.victorAwarded
			});
		return _Utils_Tuple2(
			_Utils_update(
				rewound,
				{
					drag: $author$project$Main$State$NotDragging,
					replay: $elm$core$Maybe$Just(
						{paused: false, pending: model.actionLog}),
					replayAnim: $author$project$Main$State$PreRoll(
						{untilMs: 0}),
					replayBoardRect: $elm$core$Maybe$Nothing,
					status: {kind: $author$project$Main$State$Inform, text: 'Replaying…'}
				}),
			A2(
				$elm$core$Task$attempt,
				$author$project$Main$Msg$BoardRectReceived,
				$elm$browser$Browser$Dom$getElement(
					$author$project$Main$State$boardDomIdFor(model.gameId))));
	}
};
var $author$project$Game$Replay$Time$clickReplayPauseToggle = function (model) {
	var _v0 = model.replay;
	if (_v0.$ === 'Just') {
		var progress = _v0.a;
		return _Utils_Tuple2(
			_Utils_update(
				model,
				{
					replay: $elm$core$Maybe$Just(
						_Utils_update(
							progress,
							{paused: !progress.paused}))
				}),
			$elm$core$Platform$Cmd$none);
	} else {
		return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
	}
};
var $author$project$Main$State$Animating = function (a) {
	return {$: 'Animating', a: a};
};
var $author$project$Main$State$Beating = function (a) {
	return {$: 'Beating', a: a};
};
var $author$project$Game$Replay$Space$animatedDragState = F2(
	function (anim, floaterTopLeft) {
		return $author$project$Main$State$Dragging(
			{
				boardRect: $elm$core$Maybe$Nothing,
				clickIntent: $elm$core$Maybe$Nothing,
				cursor: {x: 0, y: 0},
				floaterTopLeft: floaterTopLeft,
				gesturePath: _List_Nil,
				hoveredWing: $elm$core$Maybe$Nothing,
				originalCursor: {x: 0, y: 0},
				pathFrame: anim.pathFrame,
				source: anim.source,
				wings: _List_Nil
			});
	});
var $author$project$Game$Replay$Time$beatAfter = function (action) {
	if (action.$ === 'CompleteTurn') {
		return 2500;
	} else {
		return 800;
	}
};
var $author$project$Game$Replay$Space$elementTopLeftInViewport = function (element) {
	return {
		x: $elm$core$Basics$round(element.element.x - element.viewport.x),
		y: $elm$core$Basics$round(element.element.y - element.viewport.y)
	};
};
var $author$project$Game$Replay$Space$linearPath = F3(
	function (start, end, nowMs) {
		var samples = 12;
		var dy = end.y - start.y;
		var dx = end.x - start.x;
		var dist = $elm$core$Basics$sqrt((dx * dx) + (dy * dy));
		var duration = A2($elm$core$Basics$max, 100, dist * $author$project$Game$Replay$Space$dragMsPerPixel);
		var step = function (i) {
			var frac = i / (samples - 1);
			return {
				tMs: nowMs + (frac * duration),
				x: $elm$core$Basics$round(start.x + (dx * frac)),
				y: $elm$core$Basics$round(start.y + (dy * frac))
			};
		};
		return A2(
			$elm$core$List$map,
			step,
			A2($elm$core$List$range, 0, samples - 1));
	});
var $author$project$Game$Replay$Space$pointInLiveViewport = F2(
	function (model, loc) {
		return A2(
			$elm$core$Maybe$map,
			function (rect) {
				return {x: rect.x + loc.left, y: rect.y + loc.top};
			},
			model.replayBoardRect);
	});
var $author$project$Game$Replay$Space$stackLandingInLiveViewport = F3(
	function (model, stack, side) {
		var size = $author$project$Game$CardStack$size(stack);
		var landingLeft = function () {
			if (side.$ === 'Right') {
				return stack.loc.left + (size * $author$project$Game$BoardGeometry$cardPitch);
			} else {
				return stack.loc.left - $author$project$Game$BoardGeometry$cardPitch;
			}
		}();
		return A2(
			$author$project$Game$Replay$Space$pointInLiveViewport,
			model,
			{left: landingLeft, top: stack.loc.top});
	});
var $author$project$Game$Replay$AnimateMergeHand$finish = F5(
	function (payload, origin, nowMs, source, model) {
		return A2(
			$elm$core$Maybe$andThen,
			function (stack) {
				return A2(
					$elm$core$Maybe$map,
					function (landing) {
						return {
							path: A3($author$project$Game$Replay$Space$linearPath, origin, landing, nowMs),
							pathFrame: $author$project$Main$State$ViewportFrame,
							pendingAction: $author$project$Game$WireAction$MergeHand(payload),
							source: source,
							startMs: nowMs
						};
					},
					A3($author$project$Game$Replay$Space$stackLandingInLiveViewport, model, stack, payload.side));
			},
			A2($author$project$Game$CardStack$findStack, payload.target, model.board));
	});
var $author$project$Game$Replay$AnimatePlaceHand$finish = F5(
	function (payload, origin, nowMs, source, model) {
		return A2(
			$elm$core$Maybe$map,
			function (target) {
				return {
					path: A3($author$project$Game$Replay$Space$linearPath, origin, target, nowMs),
					pathFrame: $author$project$Main$State$ViewportFrame,
					pendingAction: $author$project$Game$WireAction$PlaceHand(payload),
					source: source,
					startMs: nowMs
				};
			},
			A2(
				$author$project$Game$Replay$Space$pointInLiveViewport,
				model,
				{left: payload.loc.left, top: payload.loc.top}));
	});
var $author$project$Game$Replay$Time$finishHandAnim = F5(
	function (action, origin, nowMs, source, model) {
		switch (action.$) {
			case 'MergeHand':
				var payload = action.a;
				return A5($author$project$Game$Replay$AnimateMergeHand$finish, payload, origin, nowMs, source, model);
			case 'PlaceHand':
				var payload = action.a;
				return A5($author$project$Game$Replay$AnimatePlaceHand$finish, payload, origin, nowMs, source, model);
			default:
				return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$Replay$Space$interpPathHelp = F3(
	function (prev, remaining, targetTs) {
		interpPathHelp:
		while (true) {
			if (!remaining.b) {
				return {x: prev.x, y: prev.y};
			} else {
				var curr = remaining.a;
				var rest = remaining.b;
				if (_Utils_cmp(curr.tMs, targetTs) > -1) {
					if (_Utils_eq(curr.tMs, prev.tMs)) {
						return {x: curr.x, y: curr.y};
					} else {
						var frac = (targetTs - prev.tMs) / (curr.tMs - prev.tMs);
						var frac_ = A3($elm$core$Basics$clamp, 0, 1, frac);
						return {
							x: $elm$core$Basics$round(prev.x + (frac_ * (curr.x - prev.x))),
							y: $elm$core$Basics$round(prev.y + (frac_ * (curr.y - prev.y)))
						};
					}
				} else {
					var $temp$prev = curr,
						$temp$remaining = rest,
						$temp$targetTs = targetTs;
					prev = $temp$prev;
					remaining = $temp$remaining;
					targetTs = $temp$targetTs;
					continue interpPathHelp;
				}
			}
		}
	});
var $author$project$Game$Replay$Space$interpPath = F2(
	function (path, elapsedMs) {
		if (!path.b) {
			return $elm$core$Maybe$Nothing;
		} else {
			var first = path.a;
			var targetTs = first.tMs + elapsedMs;
			return $elm$core$Maybe$Just(
				A3($author$project$Game$Replay$Space$interpPathHelp, first, path, targetTs));
		}
	});
var $elm$time$Time$posixToMillis = function (_v0) {
	var millis = _v0.a;
	return millis;
};
var $author$project$Game$Replay$Time$handCardRectReceived = F2(
	function (result, model) {
		var _v0 = _Utils_Tuple2(model.replayAnim, result);
		if (_v0.a.$ === 'AwaitingHandRect') {
			if (_v0.b.$ === 'Ok') {
				var ctx = _v0.a.a;
				var _v1 = _v0.b.a;
				var element = _v1.a;
				var posix = _v1.b;
				var origin = $author$project$Game$Replay$Space$elementTopLeftInViewport(element);
				var nowMs = $elm$time$Time$posixToMillis(posix);
				var maybeAnim = A5($author$project$Game$Replay$Time$finishHandAnim, ctx.action, origin, nowMs, ctx.source, model);
				var applyNow = function () {
					var modelAfter = A2($author$project$Main$Apply$applyAction, ctx.action, model).model;
					return _Utils_Tuple2(
						_Utils_update(
							modelAfter,
							{
								drag: $author$project$Main$State$NotDragging,
								replayAnim: $author$project$Main$State$Beating(
									{
										untilMs: nowMs + $author$project$Game$Replay$Time$beatAfter(ctx.action)
									})
							}),
						$elm$core$Platform$Cmd$none);
				}();
				if (maybeAnim.$ === 'Just') {
					var anim = maybeAnim.a;
					var _v3 = A2($author$project$Game$Replay$Space$interpPath, anim.path, 0);
					if (_v3.$ === 'Just') {
						var cursor = _v3.a;
						return _Utils_Tuple2(
							_Utils_update(
								model,
								{
									drag: A2($author$project$Game$Replay$Space$animatedDragState, anim, cursor),
									replayAnim: $author$project$Main$State$Animating(anim)
								}),
							$elm$core$Platform$Cmd$none);
					} else {
						return applyNow;
					}
				} else {
					return applyNow;
				}
			} else {
				var ctx = _v0.a.a;
				var err = _v0.b.a;
				var modelAfter = A2($author$project$Main$Apply$applyAction, ctx.action, model).model;
				var _v4 = A2($elm$core$Debug$log, 'HandCardRectReceived err', err);
				return _Utils_Tuple2(
					_Utils_update(
						modelAfter,
						{
							drag: $author$project$Main$State$NotDragging,
							replayAnim: $author$project$Main$State$Beating(
								{untilMs: 1000})
						}),
					$elm$core$Platform$Cmd$none);
			}
		} else {
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		}
	});
var $author$project$Main$Gesture$clearDrag = function (model) {
	return _Utils_update(
		model,
		{drag: $author$project$Main$State$NotDragging});
};
var $author$project$Main$Apply$commit = function (outcome) {
	var m = outcome.model;
	return _Utils_update(
		m,
		{status: outcome.status});
};
var $author$project$Main$Gesture$dropFootprintInBounds = F2(
	function (cardCount, loc) {
		var bounds = $author$project$Main$Apply$refereeBounds;
		return (loc.left >= 0) && ((loc.top >= 0) && ((_Utils_cmp(
			loc.left + $author$project$Game$BoardGeometry$stackWidth(cardCount),
			bounds.maxWidth) < 1) && (_Utils_cmp(loc.top + $author$project$Game$BoardGeometry$cardHeight, bounds.maxHeight) < 1)));
	});
var $author$project$Main$Gesture$dropLoc = function (info) {
	var _v0 = info.pathFrame;
	if (_v0.$ === 'BoardFrame') {
		return $elm$core$Maybe$Just(
			{left: info.floaterTopLeft.x, top: info.floaterTopLeft.y});
	} else {
		return A2(
			$elm$core$Maybe$map,
			function (rect) {
				return {left: info.floaterTopLeft.x - rect.x, top: info.floaterTopLeft.y - rect.y};
			},
			info.boardRect);
	}
};
var $author$project$Main$Gesture$droppedOffBoardScold = function (info) {
	var footprintCheck = function (cardCount) {
		var _v1 = $author$project$Main$Gesture$dropLoc(info);
		if (_v1.$ === 'Just') {
			var loc = _v1.a;
			return (!A2($author$project$Main$Gesture$dropFootprintInBounds, cardCount, loc)) ? $elm$core$Maybe$Just(
				{kind: $author$project$Main$State$Scold, text: 'Don\'t knock cards off the board, please. You\'re not a cat!'}) : $elm$core$Maybe$Nothing;
		} else {
			return $elm$core$Maybe$Nothing;
		}
	};
	var _v0 = info.source;
	if (_v0.$ === 'FromBoardStack') {
		var stack = _v0.a;
		return footprintCheck(
			$author$project$Game$CardStack$size(stack));
	} else {
		return footprintCheck(1);
	}
};
var $author$project$Main$Gesture$gestureForAction = F3(
	function (action, path, pathFrame) {
		switch (action.$) {
			case 'MergeHand':
				return $elm$core$Maybe$Nothing;
			case 'PlaceHand':
				return $elm$core$Maybe$Nothing;
			case 'Split':
				return $elm$core$Maybe$Just(
					{frame: pathFrame, path: path});
			case 'MergeStack':
				return $elm$core$Maybe$Just(
					{frame: pathFrame, path: path});
			case 'MoveStack':
				return $elm$core$Maybe$Just(
					{frame: pathFrame, path: path});
			case 'CompleteTurn':
				return $elm$core$Maybe$Nothing;
			default:
				return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$GestureArbitration$cursorInRect = F2(
	function (p, r) {
		return (_Utils_cmp(p.x, r.x) > -1) && ((_Utils_cmp(p.x, r.x + r.width) < 0) && ((_Utils_cmp(p.y, r.y) > -1) && (_Utils_cmp(p.y, r.y + r.height) < 0)));
	});
var $author$project$Main$Gesture$cursorOverBoard = function (info) {
	var _v0 = info.boardRect;
	if (_v0.$ === 'Just') {
		var rect = _v0.a;
		return A2($author$project$Game$GestureArbitration$cursorInRect, info.cursor, rect);
	} else {
		return false;
	}
};
var $author$project$Main$Gesture$resolveGesture = function (info) {
	var _v0 = _Utils_Tuple2(info.clickIntent, info.source);
	if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'FromBoardStack')) {
		var cardIdx = _v0.a.a;
		var stack = _v0.b.a;
		return $elm$core$Maybe$Just(
			$author$project$Game$WireAction$Split(
				{cardIndex: cardIdx, stack: stack}));
	} else {
		var _v1 = _Utils_Tuple2(info.hoveredWing, info.source);
		if (_v1.a.$ === 'Just') {
			if (_v1.b.$ === 'FromBoardStack') {
				var wing = _v1.a.a;
				var source = _v1.b.a;
				return $elm$core$Maybe$Just(
					$author$project$Game$WireAction$MergeStack(
						{side: wing.side, source: source, target: wing.target}));
			} else {
				var wing = _v1.a.a;
				var card = _v1.b.a;
				return $elm$core$Maybe$Just(
					$author$project$Game$WireAction$MergeHand(
						{handCard: card, side: wing.side, target: wing.target}));
			}
		} else {
			if (_v1.b.$ === 'FromHandCard') {
				var _v2 = _v1.a;
				var card = _v1.b.a;
				if ($author$project$Main$Gesture$cursorOverBoard(info)) {
					var _v3 = $author$project$Main$Gesture$dropLoc(info);
					if (_v3.$ === 'Just') {
						var loc = _v3.a;
						return A2($author$project$Main$Gesture$dropFootprintInBounds, 1, loc) ? $elm$core$Maybe$Just(
							$author$project$Game$WireAction$PlaceHand(
								{handCard: card, loc: loc})) : $elm$core$Maybe$Nothing;
					} else {
						return $elm$core$Maybe$Nothing;
					}
				} else {
					return $elm$core$Maybe$Nothing;
				}
			} else {
				var _v4 = _v1.a;
				var stack = _v1.b.a;
				if ($author$project$Main$Gesture$cursorOverBoard(info)) {
					var _v5 = $author$project$Main$Gesture$dropLoc(info);
					if (_v5.$ === 'Just') {
						var loc = _v5.a;
						return A2(
							$author$project$Main$Gesture$dropFootprintInBounds,
							$author$project$Game$CardStack$size(stack),
							loc) ? $elm$core$Maybe$Just(
							$author$project$Game$WireAction$MoveStack(
								{newLoc: loc, stack: stack})) : $elm$core$Maybe$Nothing;
					} else {
						return $elm$core$Maybe$Nothing;
					}
				} else {
					return $elm$core$Maybe$Nothing;
				}
			}
		}
	}
};
var $author$project$Main$Gesture$handleMouseUp = F3(
	function (releasePoint, tMs, model) {
		var _v0 = model.drag;
		if (_v0.$ === 'NotDragging') {
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		} else {
			var info = _v0.a;
			var modelAfterDragClear = $author$project$Main$Gesture$clearDrag(model);
			var delta = {x: releasePoint.x - info.cursor.x, y: releasePoint.y - info.cursor.y};
			var releaseFloater = {x: info.floaterTopLeft.x + delta.x, y: info.floaterTopLeft.y + delta.y};
			var fullPath = _Utils_ap(
				info.gesturePath,
				_List_fromArray(
					[
						{tMs: tMs, x: releaseFloater.x, y: releaseFloater.y}
					]));
			var infoFull = _Utils_update(
				info,
				{cursor: releasePoint, floaterTopLeft: releaseFloater, gesturePath: fullPath});
			var maybeAction = $author$project$Main$Gesture$resolveGesture(infoFull);
			var maybeGesture = function () {
				if (maybeAction.$ === 'Just') {
					var action = maybeAction.a;
					return A3($author$project$Main$Gesture$gestureForAction, action, fullPath, info.pathFrame);
				} else {
					return $elm$core$Maybe$Nothing;
				}
			}();
			var modelAfterAction = function () {
				if (maybeAction.$ === 'Just') {
					var action = maybeAction.a;
					return function (m) {
						return _Utils_update(
							m,
							{agentProgram: $elm$core$Maybe$Nothing});
					}(
						$author$project$Main$Apply$commit(
							A2($author$project$Main$Apply$applyAction, action, modelAfterDragClear)));
				} else {
					var _v5 = $author$project$Main$Gesture$droppedOffBoardScold(infoFull);
					if (_v5.$ === 'Just') {
						var status = _v5.a;
						return _Utils_update(
							modelAfterDragClear,
							{status: status});
					} else {
						return modelAfterDragClear;
					}
				}
			}();
			var _v1 = function () {
				var _v2 = _Utils_Tuple2(maybeAction, modelAfterAction.sessionId);
				if ((_v2.a.$ === 'Just') && (_v2.b.$ === 'Just')) {
					var action = _v2.a.a;
					var sid = _v2.b.a;
					var writeCmd = function () {
						var _v3 = modelAfterAction.puzzleName;
						if (_v3.$ === 'Just') {
							var name = _v3.a;
							return A4($author$project$Main$Wire$sendPuzzleAction, sid, name, action, maybeGesture);
						} else {
							return A3($author$project$Main$Wire$sendAction, sid, action, maybeGesture);
						}
					}();
					var entry = {
						action: action,
						gesturePath: A2(
							$elm$core$Maybe$map,
							function ($) {
								return $.path;
							},
							maybeGesture),
						pathFrame: A2(
							$elm$core$Maybe$withDefault,
							$author$project$Main$State$ViewportFrame,
							A2(
								$elm$core$Maybe$map,
								function ($) {
									return $.frame;
								},
								maybeGesture))
					};
					return _Utils_Tuple2(
						_Utils_update(
							modelAfterAction,
							{
								actionLog: _Utils_ap(
									modelAfterAction.actionLog,
									_List_fromArray(
										[entry]))
							}),
						writeCmd);
				} else {
					return _Utils_Tuple2(modelAfterAction, $elm$core$Platform$Cmd$none);
				}
			}();
			var finalModel = _v1.a;
			var cmd = _v1.b;
			return _Utils_Tuple2(finalModel, cmd);
		}
	});
var $author$project$Game$GestureArbitration$clickThreshold = 9;
var $author$project$Game$GestureArbitration$distSquared = F2(
	function (a, b) {
		var dy = a.y - b.y;
		var dx = a.x - b.x;
		return (dx * dx) + (dy * dy);
	});
var $author$project$Game$GestureArbitration$clickIntentAfterMove = F3(
	function (originalCursor, currentCursor, intent) {
		if (intent.$ === 'Nothing') {
			return $elm$core$Maybe$Nothing;
		} else {
			return (_Utils_cmp(
				A2($author$project$Game$GestureArbitration$distSquared, originalCursor, currentCursor),
				$author$project$Game$GestureArbitration$clickThreshold) > 0) ? $elm$core$Maybe$Nothing : intent;
		}
	});
var $elm$core$Basics$abs = function (n) {
	return (n < 0) ? (-n) : n;
};
var $author$project$Game$CardStack$stackPitch = $author$project$Game$CardStack$cardWidth + 6;
var $author$project$Game$CardStack$stackDisplayWidth = function (s) {
	return $author$project$Game$CardStack$size(s) * $author$project$Game$CardStack$stackPitch;
};
var $author$project$Game$WingOracle$eventualFloaterTopLeft = F2(
	function (wing, sourceWidth) {
		var left = function () {
			var _v0 = wing.side;
			if (_v0.$ === 'Left') {
				return wing.target.loc.left - sourceWidth;
			} else {
				return wing.target.loc.left + $author$project$Game$CardStack$stackDisplayWidth(wing.target);
			}
		}();
		return {left: left, top: wing.target.loc.top};
	});
var $author$project$Main$Gesture$wingSnapTolerance = ($author$project$Game$CardStack$stackPitch / 2) | 0;
var $author$project$Main$Gesture$nearEventualLanding = F2(
	function (info, wing) {
		var floaterWidth = function () {
			var _v2 = info.source;
			if (_v2.$ === 'FromBoardStack') {
				var stack = _v2.a;
				return $author$project$Game$CardStack$stackDisplayWidth(stack);
			} else {
				return $author$project$Game$CardStack$stackPitch;
			}
		}();
		var eventualBoard = A2($author$project$Game$WingOracle$eventualFloaterTopLeft, wing, floaterWidth);
		var eventualInFloaterFrame = function () {
			var _v1 = info.pathFrame;
			if (_v1.$ === 'BoardFrame') {
				return $elm$core$Maybe$Just(
					{x: eventualBoard.left, y: eventualBoard.top});
			} else {
				return A2(
					$elm$core$Maybe$map,
					function (rect) {
						return {x: eventualBoard.left + rect.x, y: eventualBoard.top + rect.y};
					},
					info.boardRect);
			}
		}();
		if (eventualInFloaterFrame.$ === 'Nothing') {
			return false;
		} else {
			var eventual = eventualInFloaterFrame.a;
			var dy = $elm$core$Basics$abs(info.floaterTopLeft.y - eventual.y);
			var dx = $elm$core$Basics$abs(info.floaterTopLeft.x - eventual.x);
			return (_Utils_cmp(dx, $author$project$Main$Gesture$wingSnapTolerance) < 0) && (_Utils_cmp(dy, $author$project$Main$Gesture$wingSnapTolerance) < 0);
		}
	});
var $author$project$Main$Gesture$floaterOverWing = function (info) {
	return $elm$core$List$head(
		A2(
			$elm$core$List$filter,
			$author$project$Main$Gesture$nearEventualLanding(info),
			info.wings));
};
var $author$project$Main$Gesture$wingHoverStatus = {kind: $author$project$Main$State$Inform, text: 'Drop stack to complete merge.'};
var $author$project$Main$Play$mouseMove = F3(
	function (pos, tMs, model) {
		var _v0 = model.drag;
		if (_v0.$ === 'Dragging') {
			var info = _v0.a;
			var nextIntent = A3($author$project$Game$GestureArbitration$clickIntentAfterMove, info.originalCursor, pos, info.clickIntent);
			var delta = {x: pos.x - info.cursor.x, y: pos.y - info.cursor.y};
			var nextFloater = {x: info.floaterTopLeft.x + delta.x, y: info.floaterTopLeft.y + delta.y};
			var nextPath = _Utils_ap(
				info.gesturePath,
				_List_fromArray(
					[
						{tMs: tMs, x: nextFloater.x, y: nextFloater.y}
					]));
			var nextInfo = _Utils_update(
				info,
				{clickIntent: nextIntent, cursor: pos, floaterTopLeft: nextFloater, gesturePath: nextPath});
			var hoveredWing = $author$project$Main$Gesture$floaterOverWing(nextInfo);
			var statusAfterMove = function () {
				if (!_Utils_eq(hoveredWing, info.hoveredWing)) {
					if (hoveredWing.$ === 'Just') {
						return $author$project$Main$Gesture$wingHoverStatus;
					} else {
						return model.status;
					}
				} else {
					return model.status;
				}
			}();
			var withHover = _Utils_update(
				nextInfo,
				{hoveredWing: hoveredWing});
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{
						drag: $author$project$Main$State$Dragging(withHover),
						status: statusAfterMove
					}),
				$elm$core$Platform$Cmd$none);
		} else {
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		}
	});
var $author$project$Game$Replay$Space$pathDuration = function (path) {
	var _v0 = _Utils_Tuple2(
		$elm$core$List$head(path),
		$elm$core$List$head(
			$elm$core$List$reverse(path)));
	if ((_v0.a.$ === 'Just') && (_v0.b.$ === 'Just')) {
		var first = _v0.a.a;
		var last = _v0.b.a;
		return last.tMs - first.tMs;
	} else {
		return 0;
	}
};
var $author$project$Main$State$AwaitingHandRect = function (a) {
	return {$: 'AwaitingHandRect', a: a};
};
var $author$project$Main$Msg$HandCardRectReceived = function (a) {
	return {$: 'HandCardRectReceived', a: a};
};
var $author$project$Game$HandLayout$handCardDomId = function (card) {
	return 'hand-card-v' + ($elm$core$String$fromInt(
		$author$project$Game$Card$cardValueToInt(card.value)) + ('-s' + ($elm$core$String$fromInt(
		$author$project$Game$Card$suitToInt(card.suit)) + ('-d' + function () {
		var _v0 = card.originDeck;
		if (_v0.$ === 'DeckOne') {
			return '1';
		} else {
			return '2';
		}
	}()))));
};
var $elm$time$Time$Name = function (a) {
	return {$: 'Name', a: a};
};
var $elm$time$Time$Offset = function (a) {
	return {$: 'Offset', a: a};
};
var $elm$time$Time$Zone = F2(
	function (a, b) {
		return {$: 'Zone', a: a, b: b};
	});
var $elm$time$Time$customZone = $elm$time$Time$Zone;
var $elm$time$Time$now = _Time_now($elm$time$Time$millisToPosix);
var $author$project$Game$Replay$Space$expectedStartFor = F2(
	function (action, model) {
		return A2(
			$elm$core$Maybe$map,
			$elm$core$Tuple$first,
			A2($author$project$Game$Replay$Space$boardEndpoints, action, model));
	});
var $author$project$Game$Replay$Space$pathStillValid = F3(
	function (path, action, model) {
		var _v0 = _Utils_Tuple2(
			$elm$core$List$head(path),
			A2($author$project$Game$Replay$Space$expectedStartFor, action, model));
		_v0$1:
		while (true) {
			if (_v0.a.$ === 'Just') {
				if (_v0.b.$ === 'Just') {
					var first = _v0.a.a;
					var expected = _v0.b.a;
					return _Utils_eq(first.x, expected.x) && _Utils_eq(first.y, expected.y);
				} else {
					break _v0$1;
				}
			} else {
				if (_v0.b.$ === 'Nothing') {
					break _v0$1;
				} else {
					var _v2 = _v0.a;
					return false;
				}
			}
		}
		var _v1 = _v0.b;
		return true;
	});
var $author$project$Main$State$FromHandCard = function (a) {
	return {$: 'FromHandCard', a: a};
};
var $author$project$Game$Replay$Space$handCardSource = F2(
	function (card, model) {
		var hand = $author$project$Main$State$activeHand(model);
		var present = A2(
			$elm$core$List$any,
			function (hc) {
				return _Utils_eq(hc.card, card);
			},
			hand.handCards);
		return present ? $elm$core$Maybe$Just(
			$author$project$Main$State$FromHandCard(card)) : $elm$core$Maybe$Nothing;
	});
var $author$project$Game$Replay$AnimateMergeHand$prepare = F2(
	function (payload, model) {
		return A2(
			$elm$core$Maybe$map,
			function (source) {
				return {handCardToMeasure: payload.handCard, source: source};
			},
			A2($author$project$Game$Replay$Space$handCardSource, payload.handCard, model));
	});
var $author$project$Game$Replay$AnimatePlaceHand$prepare = F2(
	function (payload, model) {
		return A2(
			$elm$core$Maybe$map,
			function (source) {
				return {handCardToMeasure: payload.handCard, source: source};
			},
			A2($author$project$Game$Replay$Space$handCardSource, payload.handCard, model));
	});
var $author$project$Game$Replay$Time$prepareResultFromMergeHand = function (r) {
	return {handCardToMeasure: r.handCardToMeasure, source: r.source};
};
var $author$project$Game$Replay$Time$prepareResultFromPlaceHand = function (r) {
	return {handCardToMeasure: r.handCardToMeasure, source: r.source};
};
var $author$project$Game$Replay$Time$prepareHandAnim = F2(
	function (action, model) {
		switch (action.$) {
			case 'MergeHand':
				var payload = action.a;
				return A2(
					$elm$core$Maybe$map,
					$author$project$Game$Replay$Time$prepareResultFromMergeHand,
					A2($author$project$Game$Replay$AnimateMergeHand$prepare, payload, model));
			case 'PlaceHand':
				var payload = action.a;
				return A2(
					$elm$core$Maybe$map,
					$author$project$Game$Replay$Time$prepareResultFromPlaceHand,
					A2($author$project$Game$Replay$AnimatePlaceHand$prepare, payload, model));
			default:
				return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Main$State$FromBoardStack = function (a) {
	return {$: 'FromBoardStack', a: a};
};
var $author$project$Game$Replay$Space$boardStackSource = F2(
	function (ref, model) {
		return A2(
			$elm$core$Maybe$map,
			$author$project$Main$State$FromBoardStack,
			A2($author$project$Game$CardStack$findStack, ref, model.board));
	});
var $author$project$Game$Replay$AnimateMergeStack$start = F5(
	function (payload, path, frame, model, nowMs) {
		return A2(
			$elm$core$Maybe$map,
			function (source) {
				return {
					path: path,
					pathFrame: frame,
					pendingAction: $author$project$Game$WireAction$MergeStack(payload),
					source: source,
					startMs: nowMs
				};
			},
			A2($author$project$Game$Replay$Space$boardStackSource, payload.source, model));
	});
var $author$project$Game$Replay$AnimateMoveStack$start = F5(
	function (payload, path, frame, model, nowMs) {
		return A2(
			$elm$core$Maybe$map,
			function (source) {
				return {
					path: path,
					pathFrame: frame,
					pendingAction: $author$project$Game$WireAction$MoveStack(payload),
					source: source,
					startMs: nowMs
				};
			},
			A2($author$project$Game$Replay$Space$boardStackSource, payload.stack, model));
	});
var $author$project$Game$Replay$Time$startBoardAnim = F5(
	function (action, path, frame, model, nowMs) {
		switch (action.$) {
			case 'Split':
				return $elm$core$Maybe$Nothing;
			case 'MergeStack':
				var payload = action.a;
				return A5($author$project$Game$Replay$AnimateMergeStack$start, payload, path, frame, model, nowMs);
			case 'MoveStack':
				var payload = action.a;
				return A5($author$project$Game$Replay$AnimateMoveStack$start, payload, path, frame, model, nowMs);
			default:
				return $elm$core$Maybe$Nothing;
		}
	});
var $author$project$Game$Replay$Time$prepareReplayStep = F5(
	function (action, maybePath, frame, model, nowMs) {
		var applyImmediate = function () {
			var modelAfter = A2($author$project$Main$Apply$applyAction, action, model).model;
			return _Utils_Tuple2(
				_Utils_update(
					modelAfter,
					{
						drag: $author$project$Main$State$NotDragging,
						replayAnim: $author$project$Main$State$Beating(
							{
								untilMs: nowMs + $author$project$Game$Replay$Time$beatAfter(action)
							})
					}),
				$elm$core$Platform$Cmd$none);
		}();
		var startAnimating = function (anim) {
			var _v8 = A2($author$project$Game$Replay$Space$interpPath, anim.path, 0);
			if (_v8.$ === 'Just') {
				var cursor = _v8.a;
				return _Utils_Tuple2(
					_Utils_update(
						model,
						{
							drag: A2($author$project$Game$Replay$Space$animatedDragState, anim, cursor),
							replayAnim: $author$project$Main$State$Animating(anim)
						}),
					$elm$core$Platform$Cmd$none);
			} else {
				return applyImmediate;
			}
		};
		var jitOrApply = function () {
			var _v4 = A3($author$project$Game$Replay$Space$synthesizeBoardPath, action, model, nowMs);
			if (_v4.$ === 'Just') {
				var _v5 = _v4.a;
				var synthPath = _v5.a;
				var synthFrame = _v5.b;
				var _v6 = A5($author$project$Game$Replay$Time$startBoardAnim, action, synthPath, synthFrame, model, nowMs);
				if (_v6.$ === 'Just') {
					var anim = _v6.a;
					return startAnimating(anim);
				} else {
					return applyImmediate;
				}
			} else {
				var _v7 = A2($author$project$Game$Replay$Time$prepareHandAnim, action, model);
				if (_v7.$ === 'Just') {
					var result = _v7.a;
					return _Utils_Tuple2(
						_Utils_update(
							model,
							{
								replayAnim: $author$project$Main$State$AwaitingHandRect(
									{action: action, source: result.source})
							}),
						A2(
							$elm$core$Task$attempt,
							$author$project$Main$Msg$HandCardRectReceived,
							A3(
								$elm$core$Task$map2,
								$elm$core$Tuple$pair,
								$elm$browser$Browser$Dom$getElement(
									$author$project$Game$HandLayout$handCardDomId(result.handCardToMeasure)),
								$elm$time$Time$now)));
				} else {
					return applyImmediate;
				}
			}
		}();
		var animateFromCaptured = function (path) {
			if (!path.b) {
				return jitOrApply;
			} else {
				var _v3 = A5($author$project$Game$Replay$Time$startBoardAnim, action, path, frame, model, nowMs);
				if (_v3.$ === 'Just') {
					var anim = _v3.a;
					return startAnimating(anim);
				} else {
					return jitOrApply;
				}
			}
		};
		if ((maybePath.$ === 'Just') && maybePath.a.b) {
			var _v1 = maybePath.a;
			var p = _v1.a;
			var rest = _v1.b;
			return A3(
				$author$project$Game$Replay$Space$pathStillValid,
				A2($elm$core$List$cons, p, rest),
				action,
				model) ? animateFromCaptured(
				A2($elm$core$List$cons, p, rest)) : jitOrApply;
		} else {
			return jitOrApply;
		}
	});
var $author$project$Game$Replay$Time$replayFrame = F2(
	function (nowMs, model) {
		var _v0 = model.replay;
		if (_v0.$ === 'Nothing') {
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		} else {
			var progress = _v0.a;
			if (progress.paused) {
				return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
			} else {
				var _v1 = model.replayAnim;
				switch (_v1.$) {
					case 'NotAnimating':
						var _v2 = progress.pending;
						if (!_v2.b) {
							return _Utils_Tuple2(
								_Utils_update(
									model,
									{drag: $author$project$Main$State$NotDragging, replay: $elm$core$Maybe$Nothing, replayAnim: $author$project$Main$State$NotAnimating}),
								$elm$core$Platform$Cmd$none);
						} else {
							var entry = _v2.a;
							var rest = _v2.b;
							var advanced = _Utils_update(
								model,
								{
									replay: $elm$core$Maybe$Just(
										_Utils_update(
											progress,
											{pending: rest}))
								});
							return A5($author$project$Game$Replay$Time$prepareReplayStep, entry.action, entry.gesturePath, entry.pathFrame, advanced, nowMs);
						}
					case 'Animating':
						var anim = _v1.a;
						var elapsed = nowMs - anim.startMs;
						var duration = $author$project$Game$Replay$Space$pathDuration(anim.path);
						if (_Utils_cmp(elapsed, duration) > -1) {
							var modelAfter = A2(
								$author$project$Main$Apply$applyAction,
								anim.pendingAction,
								_Utils_update(
									model,
									{drag: $author$project$Main$State$NotDragging})).model;
							return _Utils_Tuple2(
								_Utils_update(
									modelAfter,
									{
										replayAnim: $author$project$Main$State$Beating(
											{untilMs: nowMs + 1000})
									}),
								$elm$core$Platform$Cmd$none);
						} else {
							var _v3 = A2($author$project$Game$Replay$Space$interpPath, anim.path, elapsed);
							if (_v3.$ === 'Just') {
								var cursor = _v3.a;
								return _Utils_Tuple2(
									_Utils_update(
										model,
										{
											drag: A2($author$project$Game$Replay$Space$animatedDragState, anim, cursor)
										}),
									$elm$core$Platform$Cmd$none);
							} else {
								return _Utils_Tuple2(
									_Utils_update(
										model,
										{
											replayAnim: $author$project$Main$State$Beating(
												{untilMs: nowMs + 1000})
										}),
									$elm$core$Platform$Cmd$none);
							}
						}
					case 'Beating':
						var untilMs = _v1.a.untilMs;
						return (_Utils_cmp(nowMs, untilMs) > -1) ? _Utils_Tuple2(
							_Utils_update(
								model,
								{replayAnim: $author$project$Main$State$NotAnimating}),
							$elm$core$Platform$Cmd$none) : _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
					case 'AwaitingHandRect':
						return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
					default:
						var untilMs = _v1.a.untilMs;
						return (!untilMs) ? _Utils_Tuple2(
							_Utils_update(
								model,
								{
									replayAnim: $author$project$Main$State$PreRoll(
										{untilMs: nowMs + 1000})
								}),
							$elm$core$Platform$Cmd$none) : ((_Utils_cmp(nowMs, untilMs) > -1) ? _Utils_Tuple2(
							_Utils_update(
								model,
								{replayAnim: $author$project$Main$State$NotAnimating}),
							$elm$core$Platform$Cmd$none) : _Utils_Tuple2(model, $elm$core$Platform$Cmd$none));
				}
			}
		}
	});
var $author$project$Main$Gesture$fetchBoardRect = function (gameId) {
	return A2(
		$elm$core$Task$attempt,
		$author$project$Main$Msg$BoardRectReceived,
		$elm$browser$Browser$Dom$getElement(
			$author$project$Main$State$boardDomIdFor(gameId)));
};
var $author$project$Game$WingOracle$stackWingsForTarget = F2(
	function (source, target) {
		if (A2($author$project$Game$CardStack$stacksEqual, target, source)) {
			return _List_Nil;
		} else {
			var rightWing = function () {
				var _v1 = A3($author$project$Game$BoardActions$tryStackMerge, target, source, $author$project$Game$BoardActions$Right);
				if (_v1.$ === 'Just') {
					return _List_fromArray(
						[
							{side: $author$project$Game$BoardActions$Right, target: target}
						]);
				} else {
					return _List_Nil;
				}
			}();
			var leftWing = function () {
				var _v0 = A3($author$project$Game$BoardActions$tryStackMerge, target, source, $author$project$Game$BoardActions$Left);
				if (_v0.$ === 'Just') {
					return _List_fromArray(
						[
							{side: $author$project$Game$BoardActions$Left, target: target}
						]);
				} else {
					return _List_Nil;
				}
			}();
			return _Utils_ap(leftWing, rightWing);
		}
	});
var $author$project$Game$WingOracle$wingsForStack = F2(
	function (source, board) {
		return A2(
			$elm$core$List$concatMap,
			$author$project$Game$WingOracle$stackWingsForTarget(source),
			board);
	});
var $author$project$Main$Gesture$startBoardCardDrag = F4(
	function (_v0, clientPoint, tMs, model) {
		var stack = _v0.stack;
		var cardIndex = _v0.cardIndex;
		var _v1 = model.drag;
		if (_v1.$ === 'NotDragging') {
			var wings = A2($author$project$Game$WingOracle$wingsForStack, stack, model.board);
			var initialFloater = {x: stack.loc.left, y: stack.loc.top};
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{
						drag: $author$project$Main$State$Dragging(
							{
								boardRect: $elm$core$Maybe$Nothing,
								clickIntent: $elm$core$Maybe$Just(cardIndex),
								cursor: clientPoint,
								floaterTopLeft: initialFloater,
								gesturePath: _List_fromArray(
									[
										{tMs: tMs, x: initialFloater.x, y: initialFloater.y}
									]),
								hoveredWing: $elm$core$Maybe$Nothing,
								originalCursor: clientPoint,
								pathFrame: $author$project$Main$State$BoardFrame,
								source: $author$project$Main$State$FromBoardStack(stack),
								wings: wings
							})
					}),
				$author$project$Main$Gesture$fetchBoardRect(model.gameId));
		} else {
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		}
	});
var $author$project$Main$Gesture$findHandCard = F2(
	function (target, cards) {
		return $elm$core$List$head(
			A2(
				$elm$core$List$filter,
				function (hc) {
					return _Utils_eq(hc.card, target);
				},
				cards));
	});
var $author$project$Game$WingOracle$handCardWingsForTarget = F2(
	function (handCard, target) {
		var rightWing = function () {
			var _v1 = A3($author$project$Game$BoardActions$tryHandMerge, target, handCard, $author$project$Game$BoardActions$Right);
			if (_v1.$ === 'Just') {
				return _List_fromArray(
					[
						{side: $author$project$Game$BoardActions$Right, target: target}
					]);
			} else {
				return _List_Nil;
			}
		}();
		var leftWing = function () {
			var _v0 = A3($author$project$Game$BoardActions$tryHandMerge, target, handCard, $author$project$Game$BoardActions$Left);
			if (_v0.$ === 'Just') {
				return _List_fromArray(
					[
						{side: $author$project$Game$BoardActions$Left, target: target}
					]);
			} else {
				return _List_Nil;
			}
		}();
		return _Utils_ap(leftWing, rightWing);
	});
var $author$project$Game$WingOracle$wingsForHandCard = F2(
	function (handCard, board) {
		return A2(
			$elm$core$List$concatMap,
			$author$project$Game$WingOracle$handCardWingsForTarget(handCard),
			board);
	});
var $author$project$Main$Gesture$startHandDrag = F4(
	function (card, clientPoint, tMs, model) {
		var _v0 = _Utils_Tuple2(
			model.drag,
			A2(
				$author$project$Main$Gesture$findHandCard,
				card,
				$author$project$Main$State$activeHand(model).handCards));
		if ((_v0.a.$ === 'NotDragging') && (_v0.b.$ === 'Just')) {
			var _v1 = _v0.a;
			var handCard = _v0.b.a;
			var wings = A2($author$project$Game$WingOracle$wingsForHandCard, handCard, model.board);
			var initialFloater = {x: clientPoint.x - (($author$project$Game$CardStack$stackPitch / 2) | 0), y: clientPoint.y - 20};
			return _Utils_Tuple2(
				_Utils_update(
					model,
					{
						drag: $author$project$Main$State$Dragging(
							{
								boardRect: $elm$core$Maybe$Nothing,
								clickIntent: $elm$core$Maybe$Nothing,
								cursor: clientPoint,
								floaterTopLeft: initialFloater,
								gesturePath: _List_fromArray(
									[
										{tMs: tMs, x: initialFloater.x, y: initialFloater.y}
									]),
								hoveredWing: $elm$core$Maybe$Nothing,
								originalCursor: clientPoint,
								pathFrame: $author$project$Main$State$ViewportFrame,
								source: $author$project$Main$State$FromHandCard(card),
								wings: wings
							})
					}),
				$author$project$Main$Gesture$fetchBoardRect(model.gameId));
		} else {
			return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
		}
	});
var $author$project$Main$Play$withNoOutput = function (_v0) {
	var m = _v0.a;
	var c = _v0.b;
	return _Utils_Tuple3(m, c, $author$project$Main$Play$NoOutput);
};
var $author$project$Main$Play$update = F2(
	function (msg, model) {
		switch (msg.$) {
			case 'MouseDownOnBoardCard':
				var ref = msg.a;
				var clientPoint = msg.b;
				var tMs = msg.c;
				return $author$project$Main$Play$withNoOutput(
					A4($author$project$Main$Gesture$startBoardCardDrag, ref, clientPoint, tMs, model));
			case 'MouseDownOnHandCard':
				var idx = msg.a;
				var clientPoint = msg.b;
				var tMs = msg.c;
				return $author$project$Main$Play$withNoOutput(
					A4($author$project$Main$Gesture$startHandDrag, idx, clientPoint, tMs, model));
			case 'MouseMove':
				var pos = msg.a;
				var tMs = msg.b;
				return $author$project$Main$Play$withNoOutput(
					A3($author$project$Main$Play$mouseMove, pos, tMs, model));
			case 'MouseUp':
				var pos = msg.a;
				var tMs = msg.b;
				return $author$project$Main$Play$withNoOutput(
					A3($author$project$Main$Gesture$handleMouseUp, pos, tMs, model));
			case 'ActionSent':
				if (msg.a.$ === 'Ok') {
					return _Utils_Tuple3(model, $elm$core$Platform$Cmd$none, $author$project$Main$Play$NoOutput);
				} else {
					var err = msg.a.a;
					var _v1 = A2($elm$core$Debug$log, 'ActionSent err', err);
					return _Utils_Tuple3(
						_Utils_update(
							model,
							{
								status: {kind: $author$project$Main$State$Scold, text: 'Server rejected action — check console; state may be out of sync.'}
							}),
						$elm$core$Platform$Cmd$none,
						$author$project$Main$Play$NoOutput);
				}
			case 'SessionReceived':
				if (msg.a.$ === 'Ok') {
					var sid = msg.a.a;
					return _Utils_Tuple3(
						_Utils_update(
							model,
							{
								sessionId: $elm$core$Maybe$Just(sid)
							}),
						$author$project$Main$Wire$fetchActionLog(sid),
						$author$project$Main$Play$SessionChanged(sid));
				} else {
					var err = msg.a.a;
					var _v2 = A2($elm$core$Debug$log, 'SessionReceived err', err);
					return _Utils_Tuple3(
						_Utils_update(
							model,
							{
								status: {kind: $author$project$Main$State$Scold, text: 'Could not allocate a session — check console.'}
							}),
						$elm$core$Platform$Cmd$none,
						$author$project$Main$Play$NoOutput);
				}
			case 'ClickCompleteTurn':
				return $author$project$Main$Play$withNoOutput(
					$author$project$Main$Play$clickCompleteTurn(model));
			case 'CompleteTurnResponded':
				if (msg.a.$ === 'Ok') {
					return _Utils_Tuple3(model, $elm$core$Platform$Cmd$none, $author$project$Main$Play$NoOutput);
				} else {
					var err = msg.a.a;
					var _v3 = A2($elm$core$Debug$log, 'CompleteTurnResponded err', err);
					return _Utils_Tuple3(
						_Utils_update(
							model,
							{
								status: {kind: $author$project$Main$State$Scold, text: 'Server rejected complete-turn — check console.'}
							}),
						$elm$core$Platform$Cmd$none,
						$author$project$Main$Play$NoOutput);
				}
			case 'PopupOk':
				return _Utils_Tuple3(
					_Utils_update(
						model,
						{popup: $elm$core$Maybe$Nothing}),
					$elm$core$Platform$Cmd$none,
					$author$project$Main$Play$NoOutput);
			case 'ClickInstantReplay':
				return $author$project$Main$Play$withNoOutput(
					$author$project$Game$Replay$Time$clickInstantReplay(model));
			case 'ReplayFrame':
				var nowPosix = msg.a;
				return $author$project$Main$Play$withNoOutput(
					A2(
						$author$project$Game$Replay$Time$replayFrame,
						$elm$time$Time$posixToMillis(nowPosix),
						model));
			case 'ClickReplayPauseToggle':
				return $author$project$Main$Play$withNoOutput(
					$author$project$Game$Replay$Time$clickReplayPauseToggle(model));
			case 'HandCardRectReceived':
				var result = msg.a;
				return $author$project$Main$Play$withNoOutput(
					A2($author$project$Game$Replay$Time$handCardRectReceived, result, model));
			case 'ActionLogFetched':
				if (msg.a.$ === 'Ok') {
					var bundle = msg.a.a;
					return _Utils_Tuple3(
						A2($author$project$Main$Play$bootstrapFromBundle, bundle, model),
						$elm$core$Platform$Cmd$none,
						$author$project$Main$Play$NoOutput);
				} else {
					var err = msg.a.a;
					var _v4 = A2($elm$core$Debug$log, 'ActionLogFetched err', err);
					return _Utils_Tuple3(
						_Utils_update(
							model,
							{
								status: {kind: $author$project$Main$State$Scold, text: 'Could not load action log — check console.'}
							}),
						$elm$core$Platform$Cmd$none,
						$author$project$Main$Play$NoOutput);
				}
			case 'BoardRectReceived':
				var result = msg.a;
				return $author$project$Main$Play$withNoOutput(
					A2($author$project$Main$Play$boardRectReceived, result, model));
			case 'ClickHint':
				return $author$project$Main$Play$withNoOutput(
					$author$project$Main$Play$clickHint(model));
			default:
				return $author$project$Main$Play$withNoOutput(
					$author$project$Main$Play$clickAgentPlay(model));
		}
	});
var $author$project$Lab$update = F2(
	function (msg, model) {
		switch (msg.$) {
			case 'UpdateName':
				var s = msg.a;
				return _Utils_Tuple2(
					_Utils_update(
						model,
						{userName: s}),
					$elm$core$Platform$Cmd$none);
			case 'SubmitName':
				return ($elm$core$String$trim(model.userName) === '') ? _Utils_Tuple2(model, $elm$core$Platform$Cmd$none) : _Utils_Tuple2(
					_Utils_update(
						model,
						{started: true}),
					$author$project$Lab$fetchCatalog);
			case 'ClickFinish':
				return _Utils_Tuple2(
					_Utils_update(
						model,
						{finished: true}),
					$elm$core$Platform$Cmd$none);
			case 'CatalogFetched':
				if (msg.a.$ === 'Ok') {
					var catalog = msg.a.a;
					var _v1 = A3(
						$elm$core$List$foldr,
						F2(
							function (puzzle, _v2) {
								var accPanels = _v2.a;
								var accCmds = _v2.b;
								var _v3 = $author$project$Main$Play$init(
									$author$project$Main$Play$PuzzleSession(
										{initialState: puzzle.initialState, puzzleName: puzzle.name, sessionId: catalog.sessionId}));
								var playModel = _v3.a;
								var playCmd = _v3.b;
								return _Utils_Tuple2(
									A3(
										$elm$core$Dict$insert,
										puzzle.name,
										$author$project$Lab$Playing(playModel),
										accPanels),
									A2(
										$elm$core$List$cons,
										A2(
											$elm$core$Platform$Cmd$map,
											$author$project$Lab$PlayMsg(puzzle.name),
											playCmd),
										accCmds));
							}),
						_Utils_Tuple2($elm$core$Dict$empty, _List_Nil),
						catalog.puzzles);
					var panels = _v1.a;
					var panelCmds = _v1.b;
					return _Utils_Tuple2(
						_Utils_update(
							model,
							{
								catalog: $author$project$Lab$CatalogLoaded(catalog.puzzles),
								panels: panels,
								sessionId: $elm$core$Maybe$Just(catalog.sessionId)
							}),
						$elm$core$Platform$Cmd$batch(panelCmds));
				} else {
					var err = msg.a.a;
					return _Utils_Tuple2(
						_Utils_update(
							model,
							{
								catalog: $author$project$Lab$CatalogFailed(
									$author$project$Lab$httpErrorToString(err))
							}),
						$elm$core$Platform$Cmd$none);
				}
			case 'PlayMsg':
				var name = msg.a;
				var pmsg = msg.b;
				var _v4 = A2($elm$core$Dict$get, name, model.panels);
				if ((_v4.$ === 'Just') && (_v4.a.$ === 'Playing')) {
					var p = _v4.a.a;
					var _v5 = A2($author$project$Main$Play$update, pmsg, p);
					var p2 = _v5.a;
					var c = _v5.b;
					return _Utils_Tuple2(
						_Utils_update(
							model,
							{
								panels: A3(
									$elm$core$Dict$insert,
									name,
									$author$project$Lab$Playing(p2),
									model.panels)
							}),
						A2(
							$elm$core$Platform$Cmd$map,
							$author$project$Lab$PlayMsg(name),
							c));
				} else {
					return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
				}
			case 'UpdateAnnotation':
				var name = msg.a;
				var text = msg.b;
				var current = A2($author$project$Lab$getAnnotation, name, model);
				return _Utils_Tuple2(
					_Utils_update(
						model,
						{
							annotations: A3(
								$elm$core$Dict$insert,
								name,
								_Utils_update(
									current,
									{status: $author$project$Lab$NotSent, text: text}),
								model.annotations)
						}),
					$elm$core$Platform$Cmd$none);
			case 'SendAnnotation':
				var name = msg.a;
				var current = A2($author$project$Lab$getAnnotation, name, model);
				var trimmed = $elm$core$String$trim(current.text);
				var _v6 = _Utils_Tuple2(trimmed, model.sessionId);
				_v6$0:
				while (true) {
					if (_v6.b.$ === 'Nothing') {
						if (_v6.a === '') {
							break _v6$0;
						} else {
							var _v7 = _v6.b;
							return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
						}
					} else {
						if (_v6.a === '') {
							break _v6$0;
						} else {
							var sid = _v6.b.a;
							return _Utils_Tuple2(
								_Utils_update(
									model,
									{
										annotations: A3(
											$elm$core$Dict$insert,
											name,
											_Utils_update(
												current,
												{status: $author$project$Lab$Sending}),
											model.annotations)
									}),
								A4($author$project$Lab$sendAnnotation, sid, model.userName, name, trimmed));
						}
					}
				}
				return _Utils_Tuple2(model, $elm$core$Platform$Cmd$none);
			default:
				if (msg.b.$ === 'Ok') {
					var name = msg.a;
					return _Utils_Tuple2(
						_Utils_update(
							model,
							{
								annotations: A3(
									$elm$core$Dict$insert,
									name,
									{status: $author$project$Lab$Sent, text: ''},
									model.annotations)
							}),
						$elm$core$Platform$Cmd$none);
				} else {
					var name = msg.a;
					var err = msg.b.a;
					var current = A2($author$project$Lab$getAnnotation, name, model);
					return _Utils_Tuple2(
						_Utils_update(
							model,
							{
								annotations: A3(
									$elm$core$Dict$insert,
									name,
									_Utils_update(
										current,
										{
											status: $author$project$Lab$SendFailed(
												$author$project$Lab$httpErrorToString(err))
										}),
									model.annotations)
							}),
						$elm$core$Platform$Cmd$none);
				}
		}
	});
var $elm$html$Html$div = _VirtualDom_node('div');
var $elm$html$Html$h1 = _VirtualDom_node('h1');
var $elm$html$Html$p = _VirtualDom_node('p');
var $elm$virtual_dom$VirtualDom$style = _VirtualDom_style;
var $elm$html$Html$Attributes$style = $elm$virtual_dom$VirtualDom$style;
var $elm$virtual_dom$VirtualDom$text = _VirtualDom_text;
var $elm$html$Html$text = $elm$virtual_dom$VirtualDom$text;
var $author$project$Lab$Failed = function (a) {
	return {$: 'Failed', a: a};
};
var $elm$html$Html$h2 = _VirtualDom_node('h2');
var $author$project$Lab$SendAnnotation = function (a) {
	return {$: 'SendAnnotation', a: a};
};
var $author$project$Lab$UpdateAnnotation = F2(
	function (a, b) {
		return {$: 'UpdateAnnotation', a: a, b: b};
	});
var $elm$html$Html$button = _VirtualDom_node('button');
var $elm$json$Json$Encode$bool = _Json_wrap;
var $elm$html$Html$Attributes$boolProperty = F2(
	function (key, bool) {
		return A2(
			_VirtualDom_property,
			key,
			$elm$json$Json$Encode$bool(bool));
	});
var $elm$html$Html$Attributes$disabled = $elm$html$Html$Attributes$boolProperty('disabled');
var $elm$html$Html$label = _VirtualDom_node('label');
var $elm$virtual_dom$VirtualDom$Normal = function (a) {
	return {$: 'Normal', a: a};
};
var $elm$virtual_dom$VirtualDom$on = _VirtualDom_on;
var $elm$html$Html$Events$on = F2(
	function (event, decoder) {
		return A2(
			$elm$virtual_dom$VirtualDom$on,
			event,
			$elm$virtual_dom$VirtualDom$Normal(decoder));
	});
var $elm$html$Html$Events$onClick = function (msg) {
	return A2(
		$elm$html$Html$Events$on,
		'click',
		$elm$json$Json$Decode$succeed(msg));
};
var $elm$html$Html$Events$alwaysStop = function (x) {
	return _Utils_Tuple2(x, true);
};
var $elm$virtual_dom$VirtualDom$MayStopPropagation = function (a) {
	return {$: 'MayStopPropagation', a: a};
};
var $elm$html$Html$Events$stopPropagationOn = F2(
	function (event, decoder) {
		return A2(
			$elm$virtual_dom$VirtualDom$on,
			event,
			$elm$virtual_dom$VirtualDom$MayStopPropagation(decoder));
	});
var $elm$html$Html$Events$targetValue = A2(
	$elm$json$Json$Decode$at,
	_List_fromArray(
		['target', 'value']),
	$elm$json$Json$Decode$string);
var $elm$html$Html$Events$onInput = function (tagger) {
	return A2(
		$elm$html$Html$Events$stopPropagationOn,
		'input',
		A2(
			$elm$json$Json$Decode$map,
			$elm$html$Html$Events$alwaysStop,
			A2($elm$json$Json$Decode$map, tagger, $elm$html$Html$Events$targetValue)));
};
var $elm$html$Html$Attributes$stringProperty = F2(
	function (key, string) {
		return A2(
			_VirtualDom_property,
			key,
			$elm$json$Json$Encode$string(string));
	});
var $elm$html$Html$Attributes$placeholder = $elm$html$Html$Attributes$stringProperty('placeholder');
var $elm$html$Html$Attributes$rows = function (n) {
	return A2(
		_VirtualDom_attribute,
		'rows',
		$elm$core$String$fromInt(n));
};
var $author$project$Lab$statusText = F2(
	function (color, msg) {
		return A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'font-size', '13px'),
					A2($elm$html$Html$Attributes$style, 'color', color)
				]),
			_List_fromArray(
				[
					$elm$html$Html$text(msg)
				]));
	});
var $elm$html$Html$textarea = _VirtualDom_node('textarea');
var $elm$html$Html$Attributes$value = $elm$html$Html$Attributes$stringProperty('value');
var $author$project$Lab$viewAnnotation = F2(
	function (puzzle, ann) {
		var statusRow = function () {
			var _v0 = ann.status;
			switch (_v0.$) {
				case 'NotSent':
					return $elm$html$Html$text('');
				case 'Sending':
					return A2($author$project$Lab$statusText, '#555', 'sending…');
				case 'Sent':
					return A2($author$project$Lab$statusText, '#060', 'sent');
				default:
					var reason = _v0.a;
					return A2($author$project$Lab$statusText, '#a00', 'failed: ' + reason);
			}
		}();
		var canSend = ($elm$core$String$trim(ann.text) !== '') && (!_Utils_eq(ann.status, $author$project$Lab$Sending));
		return A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'margin-top', '16px'),
					A2($elm$html$Html$Attributes$style, 'padding-top', '12px'),
					A2($elm$html$Html$Attributes$style, 'border-top', '1px solid #ddd')
				]),
			_List_fromArray(
				[
					A2(
					$elm$html$Html$label,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'display', 'block'),
							A2($elm$html$Html$Attributes$style, 'font-size', '13px'),
							A2($elm$html$Html$Attributes$style, 'color', '#555'),
							A2($elm$html$Html$Attributes$style, 'margin-bottom', '6px')
						]),
					_List_fromArray(
						[
							$elm$html$Html$text('Notes on this puzzle (mouse slips, agent behavior, anything weird):')
						])),
					A2(
					$elm$html$Html$textarea,
					_List_fromArray(
						[
							$elm$html$Html$Attributes$value(ann.text),
							$elm$html$Html$Events$onInput(
							$author$project$Lab$UpdateAnnotation(puzzle.name)),
							$elm$html$Html$Attributes$rows(3),
							$elm$html$Html$Attributes$placeholder('e.g. \'mouse slip on seq 2\' or \'agent\'s landing loc feels off\''),
							A2($elm$html$Html$Attributes$style, 'width', '100%'),
							A2($elm$html$Html$Attributes$style, 'box-sizing', 'border-box'),
							A2($elm$html$Html$Attributes$style, 'font-family', 'inherit'),
							A2($elm$html$Html$Attributes$style, 'font-size', '14px'),
							A2($elm$html$Html$Attributes$style, 'padding', '6px')
						]),
					_List_Nil),
					A2(
					$elm$html$Html$div,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'margin-top', '8px'),
							A2($elm$html$Html$Attributes$style, 'display', 'flex'),
							A2($elm$html$Html$Attributes$style, 'align-items', 'center'),
							A2($elm$html$Html$Attributes$style, 'gap', '12px')
						]),
					_List_fromArray(
						[
							A2(
							$elm$html$Html$button,
							_List_fromArray(
								[
									$elm$html$Html$Events$onClick(
									$author$project$Lab$SendAnnotation(puzzle.name)),
									$elm$html$Html$Attributes$disabled(!canSend),
									A2($elm$html$Html$Attributes$style, 'padding', '6px 16px'),
									A2($elm$html$Html$Attributes$style, 'font-size', '13px')
								]),
							_List_fromArray(
								[
									$elm$html$Html$text('Send')
								])),
							statusRow
						]))
				]));
	});
var $elm$virtual_dom$VirtualDom$map = _VirtualDom_map;
var $elm$html$Html$map = $elm$virtual_dom$VirtualDom$map;
var $author$project$Game$View$cardHeightPx = '40px';
var $author$project$Game$View$cardWidthPx = $elm$core$String$fromInt($author$project$Game$CardStack$cardWidth) + 'px';
var $author$project$Game$Card$valueDisplayStr = function (v) {
	if (v.$ === 'Ten') {
		return '10';
	} else {
		return $author$project$Game$Card$valueStr(v);
	}
};
var $author$project$Game$View$viewCardChar = function (c) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'display', 'block'),
				A2($elm$html$Html$Attributes$style, 'user-select', 'none')
			]),
		_List_fromArray(
			[
				$elm$html$Html$text(c)
			]));
};
var $author$project$Game$View$viewPlayingCardWith = F2(
	function (extraAttrs, card) {
		var colorStr = function () {
			var _v0 = $author$project$Game$Card$cardColor(card);
			if (_v0.$ === 'Red') {
				return 'red';
			} else {
				return 'black';
			}
		}();
		var baseAttrs = _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'display', 'inline-block'),
				A2($elm$html$Html$Attributes$style, 'height', $author$project$Game$View$cardHeightPx),
				A2($elm$html$Html$Attributes$style, 'padding', '1px 1px 3px 1px'),
				A2($elm$html$Html$Attributes$style, 'user-select', 'none'),
				A2($elm$html$Html$Attributes$style, 'text-align', 'center'),
				A2($elm$html$Html$Attributes$style, 'vertical-align', 'center'),
				A2($elm$html$Html$Attributes$style, 'font-size', '17px'),
				A2($elm$html$Html$Attributes$style, 'color', colorStr),
				A2($elm$html$Html$Attributes$style, 'background-color', 'white'),
				A2($elm$html$Html$Attributes$style, 'border', '1px blue solid'),
				A2($elm$html$Html$Attributes$style, 'width', $author$project$Game$View$cardWidthPx)
			]);
		return A2(
			$elm$html$Html$div,
			_Utils_ap(baseAttrs, extraAttrs),
			_List_fromArray(
				[
					$author$project$Game$View$viewCardChar(
					$author$project$Game$Card$valueDisplayStr(card.value)),
					$author$project$Game$View$viewCardChar(
					$author$project$Game$Card$suitEmojiStr(card.suit))
				]));
	});
var $author$project$Game$View$viewCardWithAttrs = F2(
	function (extraAttrs, card) {
		return A2($author$project$Game$View$viewPlayingCardWith, extraAttrs, card);
	});
var $author$project$Game$CardStack$incomplete = function (s) {
	return _Utils_eq(
		$author$project$Game$CardStack$stackType(s),
		$author$project$Game$StackType$Incomplete);
};
var $author$project$Game$View$viewBoardCardAt = F3(
	function (cardAttrs, index, bc) {
		var stateAttrs = function () {
			var _v0 = bc.state;
			switch (_v0.$) {
				case 'FreshlyPlayed':
					return _List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'background-color', 'cyan')
						]);
				case 'FreshlyPlayedByLastPlayer':
					return _List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'background-color', 'lavender')
						]);
				default:
					return _List_Nil;
			}
		}();
		var marginAttrs = (!index) ? _List_Nil : _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'margin-left', '2px')
			]);
		return A2(
			$author$project$Game$View$viewPlayingCardWith,
			_Utils_ap(
				marginAttrs,
				_Utils_ap(stateAttrs, cardAttrs)),
			bc.card);
	});
var $author$project$Game$View$viewStackInternal = F3(
	function (stackExtraAttrs, attrsForCard, stack) {
		var isIncomplete = $author$project$Game$CardStack$incomplete(stack);
		var incompleteAttrs = isIncomplete ? _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'border', '1px gray solid'),
				A2($elm$html$Html$Attributes$style, 'background-color', 'gray')
			]) : _List_Nil;
		var cardNodes = A2(
			$elm$core$List$indexedMap,
			F2(
				function (i, bc) {
					return A3(
						$author$project$Game$View$viewBoardCardAt,
						attrsForCard(i),
						i,
						bc);
				}),
			stack.boardCards);
		var baseAttrs = _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'user-select', 'none'),
				A2($elm$html$Html$Attributes$style, 'position', 'absolute'),
				A2(
				$elm$html$Html$Attributes$style,
				'top',
				$elm$core$String$fromInt(stack.loc.top) + 'px'),
				A2(
				$elm$html$Html$Attributes$style,
				'left',
				$elm$core$String$fromInt(stack.loc.left) + 'px')
			]);
		return A2(
			$elm$html$Html$div,
			_Utils_ap(
				baseAttrs,
				_Utils_ap(incompleteAttrs, stackExtraAttrs)),
			cardNodes);
	});
var $author$project$Game$View$viewStackWithAttrs = F2(
	function (extraAttrs, stack) {
		return A3(
			$author$project$Game$View$viewStackInternal,
			extraAttrs,
			function (_v0) {
				return _List_Nil;
			},
			stack);
	});
var $author$project$Main$View$renderDraggedFloater = F2(
	function (info, positioningAttrs) {
		var y = info.floaterTopLeft.y;
		var x = info.floaterTopLeft.x;
		var floatingAttrs = _Utils_ap(
			positioningAttrs,
			_List_fromArray(
				[
					A2(
					$elm$html$Html$Attributes$style,
					'top',
					$elm$core$String$fromInt(y) + 'px'),
					A2(
					$elm$html$Html$Attributes$style,
					'left',
					$elm$core$String$fromInt(x) + 'px'),
					A2($elm$html$Html$Attributes$style, 'pointer-events', 'none'),
					A2($elm$html$Html$Attributes$style, 'z-index', '1000')
				]));
		var _v0 = info.source;
		if (_v0.$ === 'FromBoardStack') {
			var source = _v0.a;
			return A2($author$project$Game$View$viewStackWithAttrs, floatingAttrs, source);
		} else {
			var card = _v0.a;
			return A2(
				$author$project$Game$View$viewCardWithAttrs,
				_Utils_ap(
					floatingAttrs,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'background-color', 'white')
						])),
				card);
		}
	});
var $author$project$Main$View$boardDragOverlay = function (model) {
	var _v0 = model.drag;
	if (_v0.$ === 'Dragging') {
		var info = _v0.a;
		if (!_Utils_eq(info.clickIntent, $elm$core$Maybe$Nothing)) {
			return $elm$core$Maybe$Nothing;
		} else {
			var _v1 = info.pathFrame;
			if (_v1.$ === 'BoardFrame') {
				return $elm$core$Maybe$Just(
					A2(
						$author$project$Main$View$renderDraggedFloater,
						info,
						_List_fromArray(
							[
								A2($elm$html$Html$Attributes$style, 'position', 'absolute')
							])));
			} else {
				return $elm$core$Maybe$Nothing;
			}
		}
	} else {
		return $elm$core$Maybe$Nothing;
	}
};
var $author$project$Main$Msg$MouseDownOnBoardCard = F3(
	function (a, b, c) {
		return {$: 'MouseDownOnBoardCard', a: a, b: b, c: c};
	});
var $author$project$Main$Gesture$pointAndTimeDecoder = A3(
	$elm$json$Json$Decode$map2,
	$elm$core$Tuple$pair,
	$author$project$Main$Gesture$pointDecoder,
	A2($elm$json$Json$Decode$field, 'timeStamp', $elm$json$Json$Decode$float));
var $author$project$Main$Gesture$cardMouseDown = F2(
	function (stack, cardIdx) {
		return _List_fromArray(
			[
				A2(
				$elm$html$Html$Events$on,
				'mousedown',
				A2(
					$elm$json$Json$Decode$map,
					function (_v0) {
						var p = _v0.a;
						var t = _v0.b;
						return A3(
							$author$project$Main$Msg$MouseDownOnBoardCard,
							{cardIndex: cardIdx, stack: stack},
							p,
							t);
					},
					$author$project$Main$Gesture$pointAndTimeDecoder))
			]);
	});
var $author$project$Game$View$viewStack = function (stack) {
	return A2($author$project$Game$View$viewStackWithAttrs, _List_Nil, stack);
};
var $author$project$Game$View$viewStackWithCardAttrs = F2(
	function (attrsForCard, stack) {
		return A3($author$project$Game$View$viewStackInternal, _List_Nil, attrsForCard, stack);
	});
var $author$project$Main$View$viewStackForBoard = F2(
	function (drag, stack) {
		if (drag.$ === 'Dragging') {
			var info = drag.a;
			var _v1 = _Utils_Tuple2(info.source, info.clickIntent);
			if ((_v1.a.$ === 'FromBoardStack') && (_v1.b.$ === 'Nothing')) {
				var source = _v1.a.a;
				var _v2 = _v1.b;
				return A2($author$project$Game$CardStack$stacksEqual, source, stack) ? $elm$html$Html$text('') : $author$project$Game$View$viewStack(stack);
			} else {
				return A2(
					$author$project$Game$View$viewStackWithCardAttrs,
					$author$project$Main$Gesture$cardMouseDown(stack),
					stack);
			}
		} else {
			return A2(
				$author$project$Game$View$viewStackWithCardAttrs,
				$author$project$Main$Gesture$cardMouseDown(stack),
				stack);
		}
	});
var $author$project$Game$View$mergeableGreen = 'hsl(105, 72.70%, 87.10%)';
var $author$project$Game$View$mergeableHover = '#E0B0FF';
var $author$project$Game$View$viewWing = function (_v0) {
	var top = _v0.top;
	var left = _v0.left;
	var width = _v0.width;
	var bgColor = _v0.bgColor;
	var extraAttrs = _v0.extraAttrs;
	var base = _List_fromArray(
		[
			A2($elm$html$Html$Attributes$style, 'position', 'absolute'),
			A2(
			$elm$html$Html$Attributes$style,
			'top',
			$elm$core$String$fromInt(top) + 'px'),
			A2(
			$elm$html$Html$Attributes$style,
			'left',
			$elm$core$String$fromInt(left) + 'px'),
			A2(
			$elm$html$Html$Attributes$style,
			'width',
			$elm$core$String$fromInt(width) + 'px'),
			A2($elm$html$Html$Attributes$style, 'height', $author$project$Game$View$cardHeightPx),
			A2($elm$html$Html$Attributes$style, 'padding', '1px'),
			A2($elm$html$Html$Attributes$style, 'background-color', bgColor),
			A2($elm$html$Html$Attributes$style, 'user-select', 'none'),
			A2($elm$html$Html$Attributes$style, 'text-align', 'center'),
			A2($elm$html$Html$Attributes$style, 'vertical-align', 'center'),
			A2($elm$html$Html$Attributes$style, 'font-size', '17px'),
			A2($elm$html$Html$Attributes$style, 'box-sizing', 'border-box'),
			A2($elm$html$Html$Attributes$style, 'border', '1px solid transparent')
		]);
	return A2(
		$elm$html$Html$div,
		_Utils_ap(base, extraAttrs),
		_List_fromArray(
			[
				A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'color', 'transparent')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('+')
					])),
				A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'color', 'transparent')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('+')
					]))
			]));
};
var $author$project$Game$WingOracle$wingBoardRect = function (wing) {
	var left = function () {
		var _v0 = wing.side;
		if (_v0.$ === 'Left') {
			return wing.target.loc.left - $author$project$Game$CardStack$stackPitch;
		} else {
			return wing.target.loc.left + $author$project$Game$CardStack$stackDisplayWidth(wing.target);
		}
	}();
	return {height: $author$project$Game$BoardGeometry$cardHeight, left: left, top: wing.target.loc.top, width: $author$project$Game$CardStack$stackPitch};
};
var $author$project$Main$View$viewWingAt = F2(
	function (info, wing) {
		var rect = $author$project$Game$WingOracle$wingBoardRect(wing);
		var hovering = _Utils_eq(
			info.hoveredWing,
			$elm$core$Maybe$Just(wing));
		var bgColor = hovering ? $author$project$Game$View$mergeableHover : $author$project$Game$View$mergeableGreen;
		return $author$project$Game$View$viewWing(
			{bgColor: bgColor, extraAttrs: _List_Nil, left: rect.left, top: rect.top, width: rect.width});
	});
var $author$project$Main$View$boardChildren = function (model) {
	var wingNodes = function () {
		var _v1 = model.drag;
		if (_v1.$ === 'Dragging') {
			var info = _v1.a;
			return A2(
				$elm$core$List$map,
				$author$project$Main$View$viewWingAt(info),
				info.wings);
		} else {
			return _List_Nil;
		}
	}();
	var stackNodes = A2(
		$elm$core$List$map,
		$author$project$Main$View$viewStackForBoard(model.drag),
		model.board);
	var boardOverlayNodes = function () {
		var _v0 = $author$project$Main$View$boardDragOverlay(model);
		if (_v0.$ === 'Just') {
			var node = _v0.a;
			return _List_fromArray(
				[node]);
		} else {
			return _List_Nil;
		}
	}();
	return _Utils_ap(
		stackNodes,
		_Utils_ap(wingNodes, boardOverlayNodes));
};
var $author$project$Game$View$navy = '#000080';
var $author$project$Game$View$boardShellWith = F2(
	function (extraAttrs, children) {
		var baseAttrs = _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'background-color', 'khaki'),
				A2($elm$html$Html$Attributes$style, 'border', '1px solid ' + $author$project$Game$View$navy),
				A2($elm$html$Html$Attributes$style, 'border-radius', '15px'),
				A2($elm$html$Html$Attributes$style, 'position', 'relative'),
				A2($elm$html$Html$Attributes$style, 'width', '800px'),
				A2($elm$html$Html$Attributes$style, 'height', '600px'),
				A2($elm$html$Html$Attributes$style, 'margin-top', '8px')
			]);
		return A2(
			$elm$html$Html$div,
			_Utils_ap(baseAttrs, extraAttrs),
			children);
	});
var $elm$html$Html$Attributes$id = $elm$html$Html$Attributes$stringProperty('id');
var $author$project$Main$View$boardWithWings = function (model) {
	return A2(
		$author$project$Game$View$boardShellWith,
		_List_fromArray(
			[
				$elm$html$Html$Attributes$id(
				$author$project$Main$State$boardDomIdFor(model.gameId))
			]),
		$author$project$Main$View$boardChildren(model));
};
var $author$project$Game$View$sectionHeading = function (label) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'color', $author$project$Game$View$navy),
				A2($elm$html$Html$Attributes$style, 'font-weight', 'bold'),
				A2($elm$html$Html$Attributes$style, 'font-size', '19px'),
				A2($elm$html$Html$Attributes$style, 'margin-top', '20px')
			]),
		_List_fromArray(
			[
				$elm$html$Html$text(label)
			]));
};
var $author$project$Game$View$viewBoardHeading = $author$project$Game$View$sectionHeading('Board');
var $author$project$Main$View$boardColumn = function (model) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'min-width', '800px')
			]),
		_List_fromArray(
			[
				$author$project$Game$View$viewBoardHeading,
				$author$project$Main$View$boardWithWings(model)
			]));
};
var $author$project$Game$BoardGeometry$boardViewportLeft = 300;
var $author$project$Game$BoardGeometry$boardViewportTop = 38;
var $author$project$Main$View$draggedOverlay = function (model) {
	var _v0 = model.drag;
	if (_v0.$ === 'Dragging') {
		var info = _v0.a;
		if (!_Utils_eq(info.clickIntent, $elm$core$Maybe$Nothing)) {
			return $elm$html$Html$text('');
		} else {
			var _v1 = info.pathFrame;
			if (_v1.$ === 'ViewportFrame') {
				return A2(
					$author$project$Main$View$renderDraggedFloater,
					info,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'position', 'fixed')
						]));
			} else {
				return $elm$html$Html$text('');
			}
		}
	} else {
		return $elm$html$Html$text('');
	}
};
var $author$project$Main$View$deckRemainingLine = function (model) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'color', '#666'),
				A2($elm$html$Html$Attributes$style, 'font-size', '13px'),
				A2($elm$html$Html$Attributes$style, 'margin-top', '8px')
			]),
		_List_fromArray(
			[
				$elm$html$Html$text(
				'Deck: ' + ($elm$core$String$fromInt(
					$elm$core$List$length(model.deck)) + ' cards left'))
			]));
};
var $author$project$Main$Msg$MouseDownOnHandCard = F3(
	function (a, b, c) {
		return {$: 'MouseDownOnHandCard', a: a, b: b, c: c};
	});
var $author$project$Main$Gesture$handCardAttrs = F3(
	function (drag, hintedCards, hc) {
		var hintAttrs = A2(
			$elm$core$List$any,
			function (c) {
				return _Utils_eq(c, hc.card);
			},
			hintedCards) ? _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'background-color', 'lightgreen')
			]) : _List_Nil;
		return _Utils_ap(
			hintAttrs,
			function () {
				if (drag.$ === 'NotDragging') {
					return _List_fromArray(
						[
							A2(
							$elm$html$Html$Events$on,
							'mousedown',
							A2(
								$elm$json$Json$Decode$map,
								function (_v1) {
									var p = _v1.a;
									var t = _v1.b;
									return A3($author$project$Main$Msg$MouseDownOnHandCard, hc.card, p, t);
								},
								$author$project$Main$Gesture$pointAndTimeDecoder))
						]);
				} else {
					var info = drag.a;
					var _v2 = info.source;
					if (_v2.$ === 'FromHandCard') {
						var sourceCard = _v2.a;
						return _Utils_eq(sourceCard, hc.card) ? _List_fromArray(
							[
								A2($elm$html$Html$Attributes$style, 'opacity', '0.35'),
								A2($elm$html$Html$Attributes$style, 'pointer-events', 'none')
							]) : _List_fromArray(
							[
								A2($elm$html$Html$Attributes$style, 'pointer-events', 'none')
							]);
					} else {
						return _List_fromArray(
							[
								A2($elm$html$Html$Attributes$style, 'pointer-events', 'none')
							]);
					}
				}
			}());
	});
var $author$project$Main$View$listAt = F2(
	function (i, xs) {
		return $elm$core$List$head(
			A2($elm$core$List$drop, i, xs));
	});
var $author$project$Game$HandLayout$suitRowHeight = $author$project$Game$BoardGeometry$cardHeight + 12;
var $author$project$Game$View$handCardBgColor = function (hc) {
	var _v0 = hc.state;
	switch (_v0.$) {
		case 'FreshlyDrawn':
			return 'cyan';
		case 'BackFromBoard':
			return 'yellow';
		default:
			return 'white';
	}
};
var $author$project$Game$HandLayout$handLeft = 30;
var $author$project$Game$HandLayout$handTop = 100;
var $author$project$Game$HandLayout$positionAt = function (_v0) {
	var row = _v0.row;
	var col = _v0.col;
	return {x: ($author$project$Game$HandLayout$handLeft + (col * $author$project$Game$BoardGeometry$cardPitch)) + (($author$project$Game$BoardGeometry$cardPitch / 2) | 0), y: ($author$project$Game$HandLayout$handTop + (row * $author$project$Game$HandLayout$suitRowHeight)) + (($author$project$Game$BoardGeometry$cardHeight / 2) | 0)};
};
var $author$project$Game$View$viewPlacedHandCard = F2(
	function (config, slot) {
		var center = $author$project$Game$HandLayout$positionAt(
			{col: slot.col, row: slot.row});
		var localLeft = (center.x - $author$project$Game$HandLayout$handLeft) - (($author$project$Game$BoardGeometry$cardPitch / 2) | 0);
		var localTop = (center.y - $author$project$Game$HandLayout$handTop) - (($author$project$Game$BoardGeometry$cardHeight / 2) | 0);
		var positionedAttrs = _List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'position', 'absolute'),
				A2(
				$elm$html$Html$Attributes$style,
				'top',
				$elm$core$String$fromInt(localTop) + 'px'),
				A2(
				$elm$html$Html$Attributes$style,
				'left',
				$elm$core$String$fromInt(localLeft) + 'px'),
				A2($elm$html$Html$Attributes$style, 'cursor', 'grab'),
				A2(
				$elm$html$Html$Attributes$style,
				'background-color',
				$author$project$Game$View$handCardBgColor(slot.handCard)),
				$elm$html$Html$Attributes$id(
				$author$project$Game$HandLayout$handCardDomId(slot.handCard.card))
			]);
		return A2(
			$author$project$Game$View$viewPlayingCardWith,
			_Utils_ap(
				positionedAttrs,
				config.attrsForCard(slot.handCard)),
			slot.handCard.card);
	});
var $author$project$Game$View$viewHand = F2(
	function (config, hand) {
		var rows = $elm$core$List$concat(
			A2(
				$elm$core$List$indexedMap,
				F2(
					function (rowIdx, suit) {
						return A2(
							$elm$core$List$indexedMap,
							F2(
								function (colIdx, hc) {
									return {col: colIdx, handCard: hc, row: rowIdx};
								}),
							A2(
								$elm$core$List$sortBy,
								function (hc) {
									return $author$project$Game$Card$cardValueToInt(hc.card.value);
								},
								A2(
									$elm$core$List$filter,
									function (hc) {
										return _Utils_eq(hc.card.suit, suit);
									},
									hand.handCards)));
					}),
				$author$project$Game$Card$allSuits));
		var containerHeight = 4 * $author$project$Game$HandLayout$suitRowHeight;
		return A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'position', 'relative'),
					A2(
					$elm$html$Html$Attributes$style,
					'width',
					$elm$core$String$fromInt(240 - 20) + 'px'),
					A2(
					$elm$html$Html$Attributes$style,
					'height',
					$elm$core$String$fromInt(containerHeight) + 'px')
				]),
			A2(
				$elm$core$List$map,
				$author$project$Game$View$viewPlacedHandCard(config),
				rows));
	});
var $author$project$Game$View$viewHandHeading = $author$project$Game$View$sectionHeading('Hand');
var $author$project$Main$Msg$ClickCompleteTurn = {$: 'ClickCompleteTurn'};
var $author$project$Main$Msg$ClickHint = {$: 'ClickHint'};
var $author$project$Main$Msg$ClickInstantReplay = {$: 'ClickInstantReplay'};
var $author$project$Main$Msg$ClickReplayPauseToggle = {$: 'ClickReplayPauseToggle'};
var $author$project$Main$View$gameButton = F2(
	function (label, msg) {
		return A2(
			$elm$html$Html$button,
			_List_fromArray(
				[
					$elm$html$Html$Events$onClick(msg),
					A2($elm$html$Html$Attributes$style, 'padding', '6px 12px'),
					A2($elm$html$Html$Attributes$style, 'font-size', '14px'),
					A2($elm$html$Html$Attributes$style, 'border', '1px solid ' + $author$project$Game$View$navy),
					A2($elm$html$Html$Attributes$style, 'background', 'white'),
					A2($elm$html$Html$Attributes$style, 'color', $author$project$Game$View$navy),
					A2($elm$html$Html$Attributes$style, 'border-radius', '3px'),
					A2($elm$html$Html$Attributes$style, 'cursor', 'pointer')
				]),
			_List_fromArray(
				[
					$elm$html$Html$text(label)
				]));
	});
var $elm$html$Html$a = _VirtualDom_node('a');
var $elm$html$Html$Attributes$href = function (url) {
	return A2(
		$elm$html$Html$Attributes$stringProperty,
		'href',
		_VirtualDom_noJavaScriptUri(url));
};
var $author$project$Main$View$gameLink = F2(
	function (label, url) {
		return A2(
			$elm$html$Html$a,
			_List_fromArray(
				[
					$elm$html$Html$Attributes$href(url),
					A2($elm$html$Html$Attributes$style, 'padding', '6px 12px'),
					A2($elm$html$Html$Attributes$style, 'font-size', '14px'),
					A2($elm$html$Html$Attributes$style, 'border', '1px solid ' + $author$project$Game$View$navy),
					A2($elm$html$Html$Attributes$style, 'background', 'white'),
					A2($elm$html$Html$Attributes$style, 'color', $author$project$Game$View$navy),
					A2($elm$html$Html$Attributes$style, 'border-radius', '3px'),
					A2($elm$html$Html$Attributes$style, 'cursor', 'pointer'),
					A2($elm$html$Html$Attributes$style, 'text-decoration', 'none')
				]),
			_List_fromArray(
				[
					$elm$html$Html$text(label)
				]));
	});
var $author$project$Main$View$viewTurnControls = function (model) {
	var replayControl = function () {
		var _v0 = model.replay;
		if (_v0.$ === 'Just') {
			var progress = _v0.a;
			return progress.paused ? A2($author$project$Main$View$gameButton, 'Resume', $author$project$Main$Msg$ClickReplayPauseToggle) : A2($author$project$Main$View$gameButton, 'Pause', $author$project$Main$Msg$ClickReplayPauseToggle);
		} else {
			return A2($author$project$Main$View$gameButton, 'Instant replay', $author$project$Main$Msg$ClickInstantReplay);
		}
	}();
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'margin-top', '12px'),
				A2($elm$html$Html$Attributes$style, 'display', 'flex'),
				A2($elm$html$Html$Attributes$style, 'gap', '8px'),
				A2($elm$html$Html$Attributes$style, 'flex-wrap', 'wrap')
			]),
		_List_fromArray(
			[
				A2($author$project$Main$View$gameButton, 'Complete turn', $author$project$Main$Msg$ClickCompleteTurn),
				A2($author$project$Main$View$gameButton, 'Hint', $author$project$Main$Msg$ClickHint),
				replayControl,
				A2($author$project$Main$View$gameLink, '← Lobby', '/gopher/game-lobby')
			]));
};
var $author$project$Main$View$viewPlayerRow = F3(
	function (model, idx, hand) {
		var turnDelta = model.score - model.turnStartBoardScore;
		var turnDeltaText = (turnDelta >= 0) ? ('+' + $elm$core$String$fromInt(turnDelta)) : $elm$core$String$fromInt(turnDelta);
		var playerTotal = function () {
			var _v0 = A2($author$project$Main$View$listAt, idx, model.scores);
			if (_v0.$ === 'Just') {
				var n = _v0.a;
				return n;
			} else {
				return 0;
			}
		}();
		var playerName = 'Player ' + $elm$core$String$fromInt(idx + 1);
		var isActive = _Utils_eq(idx, model.activePlayerIndex);
		var nameColor = isActive ? $author$project$Game$View$navy : '#666';
		var nameSuffix = isActive ? ' (your turn)' : '';
		var turnDeltaLine = isActive ? _List_fromArray(
			[
				A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'color', '#555'),
						A2($elm$html$Html$Attributes$style, 'font-size', '13px'),
						A2($elm$html$Html$Attributes$style, 'margin-bottom', '6px')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('Turn: ' + turnDeltaText)
					]))
			]) : _List_Nil;
		return A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'padding-bottom', '15px'),
					A2($elm$html$Html$Attributes$style, 'margin-bottom', '12px'),
					A2($elm$html$Html$Attributes$style, 'border-bottom', '1px #000080 solid')
				]),
			_Utils_ap(
				_List_fromArray(
					[
						A2(
						$elm$html$Html$div,
						_List_fromArray(
							[
								A2($elm$html$Html$Attributes$style, 'font-weight', 'bold'),
								A2($elm$html$Html$Attributes$style, 'font-size', '16px'),
								A2($elm$html$Html$Attributes$style, 'color', nameColor),
								A2($elm$html$Html$Attributes$style, 'margin-top', '8px')
							]),
						_List_fromArray(
							[
								$elm$html$Html$text(
								_Utils_ap(playerName, nameSuffix))
							])),
						A2(
						$elm$html$Html$div,
						_List_fromArray(
							[
								A2($elm$html$Html$Attributes$style, 'color', 'maroon'),
								A2($elm$html$Html$Attributes$style, 'margin-bottom', '4px'),
								A2($elm$html$Html$Attributes$style, 'margin-top', '4px')
							]),
						_List_fromArray(
							[
								$elm$html$Html$text(
								'Score: ' + $elm$core$String$fromInt(playerTotal))
							]))
					]),
				_Utils_ap(
					turnDeltaLine,
					isActive ? _List_fromArray(
						[
							$author$project$Game$View$viewHandHeading,
							A2(
							$author$project$Game$View$viewHand,
							{
								attrsForCard: A2($author$project$Main$Gesture$handCardAttrs, model.drag, model.hintedCards)
							},
							hand),
							$author$project$Main$View$viewTurnControls(model)
						]) : _List_fromArray(
						[
							A2(
							$elm$html$Html$div,
							_List_fromArray(
								[
									A2($elm$html$Html$Attributes$style, 'color', '#888'),
									A2($elm$html$Html$Attributes$style, 'font-size', '13px')
								]),
							_List_fromArray(
								[
									$elm$html$Html$text(
									$elm$core$String$fromInt(
										$elm$core$List$length(hand.handCards)) + ' cards')
								]))
						]))));
	});
var $author$project$Main$View$playerHands = function (model) {
	return _Utils_ap(
		A2(
			$elm$core$List$cons,
			A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'color', '#666'),
						A2($elm$html$Html$Attributes$style, 'font-size', '13px'),
						A2($elm$html$Html$Attributes$style, 'margin-top', '12px')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text(
						'Turn ' + $elm$core$String$fromInt(model.turnIndex + 1))
					])),
			A2(
				$elm$core$List$indexedMap,
				$author$project$Main$View$viewPlayerRow(model),
				model.hands)),
		_List_fromArray(
			[
				$author$project$Main$View$deckRemainingLine(model)
			]));
};
var $author$project$Main$Msg$ClickAgentPlay = {$: 'ClickAgentPlay'};
var $author$project$Main$View$puzzleControls = function (model) {
	var replayControl = function () {
		var _v0 = model.replay;
		if (_v0.$ === 'Just') {
			var progress = _v0.a;
			return progress.paused ? A2($author$project$Main$View$gameButton, 'Resume', $author$project$Main$Msg$ClickReplayPauseToggle) : A2($author$project$Main$View$gameButton, 'Pause', $author$project$Main$Msg$ClickReplayPauseToggle);
		} else {
			return A2($author$project$Main$View$gameButton, 'Instant replay', $author$project$Main$Msg$ClickInstantReplay);
		}
	}();
	return _List_fromArray(
		[
			A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'padding-top', '12px'),
					A2($elm$html$Html$Attributes$style, 'display', 'flex'),
					A2($elm$html$Html$Attributes$style, 'flex-direction', 'column'),
					A2($elm$html$Html$Attributes$style, 'gap', '10px'),
					A2($elm$html$Html$Attributes$style, 'align-items', 'stretch')
				]),
			_List_fromArray(
				[
					A2($author$project$Main$View$gameButton, 'Hint', $author$project$Main$Msg$ClickHint),
					A2($author$project$Main$View$gameButton, 'Let agent play', $author$project$Main$Msg$ClickAgentPlay),
					replayControl
				]))
		]);
};
var $author$project$Main$View$leftSidebar = function (model) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'min-width', '240px'),
				A2($elm$html$Html$Attributes$style, 'padding-right', '20px'),
				A2($elm$html$Html$Attributes$style, 'border-right', '1px gray solid')
			]),
		model.hideTurnControls ? $author$project$Main$View$puzzleControls(model) : $author$project$Main$View$playerHands(model));
};
var $author$project$Main$Msg$PopupOk = {$: 'PopupOk'};
var $elm$html$Html$pre = _VirtualDom_node('pre');
var $author$project$Main$View$viewPopup = function (maybePopup) {
	if (maybePopup.$ === 'Nothing') {
		return $elm$html$Html$text('');
	} else {
		var admin = maybePopup.a.admin;
		var body = maybePopup.a.body;
		return A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'position', 'fixed'),
					A2($elm$html$Html$Attributes$style, 'inset', '0'),
					A2($elm$html$Html$Attributes$style, 'background-color', 'rgba(0, 0, 0, 0.45)'),
					A2($elm$html$Html$Attributes$style, 'display', 'flex'),
					A2($elm$html$Html$Attributes$style, 'align-items', 'center'),
					A2($elm$html$Html$Attributes$style, 'justify-content', 'center'),
					A2($elm$html$Html$Attributes$style, 'z-index', '2000')
				]),
			_List_fromArray(
				[
					A2(
					$elm$html$Html$div,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'background', 'white'),
							A2($elm$html$Html$Attributes$style, 'border', '1px solid ' + $author$project$Game$View$navy),
							A2($elm$html$Html$Attributes$style, 'border-radius', '12px'),
							A2($elm$html$Html$Attributes$style, 'padding', '24px 28px'),
							A2($elm$html$Html$Attributes$style, 'max-width', '420px'),
							A2($elm$html$Html$Attributes$style, 'box-shadow', '0 10px 30px rgba(0, 0, 0, 0.25)')
						]),
					_List_fromArray(
						[
							A2(
							$elm$html$Html$div,
							_List_fromArray(
								[
									A2($elm$html$Html$Attributes$style, 'font-weight', 'bold'),
									A2($elm$html$Html$Attributes$style, 'color', $author$project$Game$View$navy),
									A2($elm$html$Html$Attributes$style, 'font-size', '15px'),
									A2($elm$html$Html$Attributes$style, 'margin-bottom', '10px')
								]),
							_List_fromArray(
								[
									$elm$html$Html$text(admin)
								])),
							A2(
							$elm$html$Html$pre,
							_List_fromArray(
								[
									A2($elm$html$Html$Attributes$style, 'font-family', 'inherit'),
									A2($elm$html$Html$Attributes$style, 'white-space', 'pre-wrap'),
									A2($elm$html$Html$Attributes$style, 'margin', '0 0 18px 0'),
									A2($elm$html$Html$Attributes$style, 'font-size', '14px'),
									A2($elm$html$Html$Attributes$style, 'line-height', '1.45')
								]),
							_List_fromArray(
								[
									$elm$html$Html$text(body)
								])),
							A2(
							$elm$html$Html$button,
							_List_fromArray(
								[
									$elm$html$Html$Events$onClick($author$project$Main$Msg$PopupOk),
									A2($elm$html$Html$Attributes$style, 'background', $author$project$Game$View$navy),
									A2($elm$html$Html$Attributes$style, 'color', 'white'),
									A2($elm$html$Html$Attributes$style, 'border', 'none'),
									A2($elm$html$Html$Attributes$style, 'padding', '8px 20px'),
									A2($elm$html$Html$Attributes$style, 'border-radius', '4px'),
									A2($elm$html$Html$Attributes$style, 'cursor', 'pointer'),
									A2($elm$html$Html$Attributes$style, 'font-size', '14px')
								]),
							_List_fromArray(
								[
									$elm$html$Html$text('OK')
								]))
						]))
				]));
	}
};
var $author$project$Main$View$viewStatusBar = function (status) {
	var color = function () {
		var _v0 = status.kind;
		switch (_v0.$) {
			case 'Inform':
				return '#31708f';
			case 'Celebrate':
				return 'green';
			default:
				return 'red';
		}
	}();
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'padding', '6px 20px'),
				A2($elm$html$Html$Attributes$style, 'font-size', '15px'),
				A2($elm$html$Html$Attributes$style, 'color', color),
				A2($elm$html$Html$Attributes$style, 'border-bottom', '1px solid #eee')
			]),
		_List_fromArray(
			[
				$elm$html$Html$text(status.text)
			]));
};
var $author$project$Main$View$view = function (model) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'font-family', 'system-ui, sans-serif'),
				A2($elm$html$Html$Attributes$style, 'position', 'relative'),
				A2($elm$html$Html$Attributes$style, 'width', '1100px'),
				A2($elm$html$Html$Attributes$style, 'height', '700px'),
				A2($elm$html$Html$Attributes$style, 'overflow', 'hidden'),
				A2($elm$html$Html$Attributes$style, 'background', '#f4f4ec')
			]),
		_List_fromArray(
			[
				A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'position', 'absolute'),
						A2($elm$html$Html$Attributes$style, 'top', '0'),
						A2($elm$html$Html$Attributes$style, 'left', '0'),
						A2($elm$html$Html$Attributes$style, 'right', '0')
					]),
				_List_fromArray(
					[
						$author$project$Main$View$viewStatusBar(model.status)
					])),
				A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'position', 'absolute'),
						A2(
						$elm$html$Html$Attributes$style,
						'top',
						$elm$core$String$fromInt($author$project$Game$BoardGeometry$boardViewportTop) + 'px'),
						A2($elm$html$Html$Attributes$style, 'left', '20px'),
						A2(
						$elm$html$Html$Attributes$style,
						'width',
						$elm$core$String$fromInt($author$project$Game$BoardGeometry$boardViewportLeft - 40) + 'px')
					]),
				_List_fromArray(
					[
						$author$project$Main$View$leftSidebar(model)
					])),
				A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'position', 'absolute'),
						A2(
						$elm$html$Html$Attributes$style,
						'top',
						$elm$core$String$fromInt($author$project$Game$BoardGeometry$boardViewportTop) + 'px'),
						A2(
						$elm$html$Html$Attributes$style,
						'left',
						$elm$core$String$fromInt($author$project$Game$BoardGeometry$boardViewportLeft) + 'px')
					]),
				_List_fromArray(
					[
						$author$project$Main$View$boardColumn(model)
					])),
				$author$project$Main$View$draggedOverlay(model),
				$author$project$Main$View$viewPopup(
				function () {
					var _v0 = model.replay;
					if (_v0.$ === 'Just') {
						return $elm$core$Maybe$Nothing;
					} else {
						return model.popup;
					}
				}())
			]));
};
var $author$project$Main$Play$view = $author$project$Main$View$view;
var $author$project$Lab$viewPanelBody = F2(
	function (puzzle, panel) {
		if (panel.$ === 'Playing') {
			var p = panel.a;
			return A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'margin-top', '12px')
					]),
				_List_fromArray(
					[
						A2(
						$elm$html$Html$map,
						$author$project$Lab$PlayMsg(puzzle.name),
						$author$project$Main$Play$view(p))
					]));
		} else {
			var reason = panel.a;
			return A2(
				$elm$html$Html$div,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'margin-top', '12px'),
						A2($elm$html$Html$Attributes$style, 'color', '#a00')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('Could not load puzzle: ' + reason)
					]));
		}
	});
var $author$project$Lab$viewPuzzle = F2(
	function (model, puzzle) {
		var panel = A2(
			$elm$core$Maybe$withDefault,
			$author$project$Lab$Failed('panel missing — race or bug'),
			A2($elm$core$Dict$get, puzzle.name, model.panels));
		return A2(
			$elm$html$Html$div,
			_List_fromArray(
				[
					A2($elm$html$Html$Attributes$style, 'border', '1px solid #ccc'),
					A2($elm$html$Html$Attributes$style, 'border-radius', '6px'),
					A2($elm$html$Html$Attributes$style, 'padding', '16px'),
					A2($elm$html$Html$Attributes$style, 'margin-top', '28px'),
					A2($elm$html$Html$Attributes$style, 'background', '#fafafa')
				]),
			_List_fromArray(
				[
					A2(
					$elm$html$Html$h2,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'margin-top', '0')
						]),
					_List_fromArray(
						[
							$elm$html$Html$text(puzzle.title)
						])),
					A2($author$project$Lab$viewPanelBody, puzzle, panel),
					A2(
					$author$project$Lab$viewAnnotation,
					puzzle,
					A2($author$project$Lab$getAnnotation, puzzle.name, model))
				]));
	});
var $author$project$Lab$viewCatalog = function (model) {
	var _v0 = model.catalog;
	switch (_v0.$) {
		case 'CatalogLoading':
			return _List_fromArray(
				[
					A2(
					$elm$html$Html$div,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'margin-top', '24px'),
							A2($elm$html$Html$Attributes$style, 'color', '#666')
						]),
					_List_fromArray(
						[
							$elm$html$Html$text('Loading catalog…')
						]))
				]);
		case 'CatalogFailed':
			var reason = _v0.a;
			return _List_fromArray(
				[
					A2(
					$elm$html$Html$div,
					_List_fromArray(
						[
							A2($elm$html$Html$Attributes$style, 'margin-top', '24px'),
							A2($elm$html$Html$Attributes$style, 'color', '#a00')
						]),
					_List_fromArray(
						[
							$elm$html$Html$text('Could not load puzzle catalog: ' + reason)
						]))
				]);
		default:
			var puzzles = _v0.a;
			return A2(
				$elm$core$List$map,
				$author$project$Lab$viewPuzzle(model),
				puzzles);
	}
};
var $author$project$Lab$ClickFinish = {$: 'ClickFinish'};
var $author$project$Lab$viewFinishButton = A2(
	$elm$html$Html$div,
	_List_fromArray(
		[
			A2($elm$html$Html$Attributes$style, 'margin-top', '40px'),
			A2($elm$html$Html$Attributes$style, 'padding-top', '20px'),
			A2($elm$html$Html$Attributes$style, 'border-top', '1px solid #ddd'),
			A2($elm$html$Html$Attributes$style, 'text-align', 'center')
		]),
	_List_fromArray(
		[
			A2(
			$elm$html$Html$button,
			_List_fromArray(
				[
					$elm$html$Html$Events$onClick($author$project$Lab$ClickFinish),
					A2($elm$html$Html$Attributes$style, 'padding', '12px 32px'),
					A2($elm$html$Html$Attributes$style, 'font-size', '16px'),
					A2($elm$html$Html$Attributes$style, 'background', '#000080'),
					A2($elm$html$Html$Attributes$style, 'color', 'white'),
					A2($elm$html$Html$Attributes$style, 'border', 'none'),
					A2($elm$html$Html$Attributes$style, 'border-radius', '6px'),
					A2($elm$html$Html$Attributes$style, 'cursor', 'pointer')
				]),
			_List_fromArray(
				[
					$elm$html$Html$text('Finish')
				]))
		]));
var $author$project$Lab$viewFinishedMessage = function (model) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'margin-top', '40px'),
				A2($elm$html$Html$Attributes$style, 'padding', '32px'),
				A2($elm$html$Html$Attributes$style, 'background', '#f0f8f0'),
				A2($elm$html$Html$Attributes$style, 'border', '1px solid #9c9'),
				A2($elm$html$Html$Attributes$style, 'border-radius', '8px'),
				A2($elm$html$Html$Attributes$style, 'text-align', 'center'),
				A2($elm$html$Html$Attributes$style, 'font-size', '18px')
			]),
		_List_fromArray(
			[
				A2(
				$elm$html$Html$p,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'margin', '0 0 8px 0'),
						A2($elm$html$Html$Attributes$style, 'font-weight', 'bold')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text(
						'Thanks, ' + ($elm$core$String$trim(model.userName) + '! You are helping science!'))
					])),
				A2(
				$elm$html$Html$p,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'margin', '0'),
						A2($elm$html$Html$Attributes$style, 'font-size', '14px'),
						A2($elm$html$Html$Attributes$style, 'color', '#555')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('(you may reload the browser to play again)')
					]))
			]));
};
var $author$project$Lab$SubmitName = {$: 'SubmitName'};
var $author$project$Lab$UpdateName = function (a) {
	return {$: 'UpdateName', a: a};
};
var $elm$html$Html$input = _VirtualDom_node('input');
var $elm$html$Html$Attributes$type_ = $elm$html$Html$Attributes$stringProperty('type');
var $author$project$Lab$viewNameGate = function (model) {
	var trimmed = $elm$core$String$trim(model.userName);
	var canStart = trimmed !== '';
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'border', '1px solid #ccc'),
				A2($elm$html$Html$Attributes$style, 'border-radius', '6px'),
				A2($elm$html$Html$Attributes$style, 'padding', '20px'),
				A2($elm$html$Html$Attributes$style, 'margin-top', '28px'),
				A2($elm$html$Html$Attributes$style, 'background', '#fafafa')
			]),
		_List_fromArray(
			[
				A2(
				$elm$html$Html$p,
				_List_Nil,
				_List_fromArray(
					[
						$elm$html$Html$text('Your name will be included in the session labels so ' + ('we can tell your attempts apart from others\' when ' + 'we study the captures later.'))
					])),
				A2(
				$elm$html$Html$label,
				_List_fromArray(
					[
						A2($elm$html$Html$Attributes$style, 'display', 'block'),
						A2($elm$html$Html$Attributes$style, 'margin-bottom', '12px')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('Your name: '),
						A2(
						$elm$html$Html$input,
						_List_fromArray(
							[
								$elm$html$Html$Attributes$type_('text'),
								$elm$html$Html$Attributes$value(model.userName),
								$elm$html$Html$Events$onInput($author$project$Lab$UpdateName),
								$elm$html$Html$Attributes$placeholder('first name is fine'),
								A2($elm$html$Html$Attributes$style, 'font-size', '15px'),
								A2($elm$html$Html$Attributes$style, 'padding', '4px 8px'),
								A2($elm$html$Html$Attributes$style, 'margin-left', '8px'),
								A2($elm$html$Html$Attributes$style, 'min-width', '200px')
							]),
						_List_Nil)
					])),
				A2(
				$elm$html$Html$button,
				_List_fromArray(
					[
						$elm$html$Html$Events$onClick($author$project$Lab$SubmitName),
						$elm$html$Html$Attributes$disabled(!canStart),
						A2($elm$html$Html$Attributes$style, 'padding', '8px 20px'),
						A2($elm$html$Html$Attributes$style, 'font-size', '14px')
					]),
				_List_fromArray(
					[
						$elm$html$Html$text('Start')
					]))
			]));
};
var $author$project$Lab$view = function (model) {
	return A2(
		$elm$html$Html$div,
		_List_fromArray(
			[
				A2($elm$html$Html$Attributes$style, 'max-width', '1200px'),
				A2($elm$html$Html$Attributes$style, 'margin', '0 auto'),
				A2($elm$html$Html$Attributes$style, 'padding', '24px'),
				A2($elm$html$Html$Attributes$style, 'font-family', 'sans-serif')
			]),
		_Utils_ap(
			_List_fromArray(
				[
					A2(
					$elm$html$Html$h1,
					_List_Nil,
					_List_fromArray(
						[
							$elm$html$Html$text('BOARD_LAB')
						])),
					A2(
					$elm$html$Html$p,
					_List_Nil,
					_List_fromArray(
						[
							$elm$html$Html$text('A gallery of hand-crafted LynRummy puzzles. Each ' + ('loads ready to play. Scroll down after solving ' + ('one to reach the next. Drags get captured into ' + ('SQLite so the Python agent can study your ' + 'spatial choices.'))))
						]))
				]),
			model.finished ? _List_fromArray(
				[
					$author$project$Lab$viewFinishedMessage(model)
				]) : (model.started ? _Utils_ap(
				$author$project$Lab$viewCatalog(model),
				_List_fromArray(
					[$author$project$Lab$viewFinishButton])) : _List_fromArray(
				[
					$author$project$Lab$viewNameGate(model)
				]))));
};
var $author$project$Lab$main = $elm$browser$Browser$element(
	{init: $author$project$Lab$init, subscriptions: $author$project$Lab$subscriptions, update: $author$project$Lab$update, view: $author$project$Lab$view});
_Platform_export({'Lab':{'init':$author$project$Lab$main(
	$elm$json$Json$Decode$succeed(_Utils_Tuple0))(0)}});}(this));