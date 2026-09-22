// Actual renderer regression plus a proposal-only three-valued reference model.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[3]);
const source = fs.readFileSync(process.argv[2], 'utf8');
const ast = ts.createSourceFile('condition-plan.ts', source, ts.ScriptTarget.Latest, true);
const fn = ast.statements.find(s => ts.isFunctionDeclaration(s) && s.name?.text === 'renderBool');
assert(fn);
const js = ts.transpileModule(fn.getText(ast), {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
const ctx = {renderNum:n=>String(n.value),OP_WORD:{'==':'equals'}};
vm.createContext(ctx); vm.runInContext(js,ctx);
const leaf = name => ({op:'cmp',cmp:'==',left:{value:name},right:{value:1}});
const A=leaf('A'),B=leaf('B'),C=leaf('C');
const one=ctx.renderBool({op:'and',args:[{op:'or',args:[A,B]},C]});
const two=ctx.renderBool({op:'or',args:[A,{op:'and',args:[B,C]}]});
assert.equal(one,'(A equals 1 OR B equals 1) AND C equals 1');
assert.equal(two,'A equals 1 OR (B equals 1 AND C equals 1)');
assert.notEqual(one,two);
console.log('PASS actual ae569c6b renderer: AND/OR grouping is preserved');
console.log(one);console.log(two);

// Three-valued reference semantics: 0=false, 1=true, 2=unknown. This is NOT
// a test of a deployed on-chain projection compiler, which is not present.
let seed=0x270;
function next(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;}
function tree(depth){if(!depth)return {leaf:next()%4};const op=next()%3;return op===2?{op,args:[tree(depth-1)]}:{op,args:[tree(depth-1),tree(depth-1)]};}
function tri(t,truths,known){if('leaf'in t)return known&(1<<t.leaf)?(truths>>t.leaf)&1:2;const a=tri(t.args[0],truths,known);if(t.op===2)return a===2?2:1-a;const b=tri(t.args[1],truths,known);return t.op===0?(a===0||b===0?0:a===1&&b===1?1:2):(a===1||b===1?1:a===0&&b===0?0:2);}
function bound(t,truths,known,upper){if('leaf'in t)return known&(1<<t.leaf)?Boolean(truths&(1<<t.leaf)):upper;if(t.op===2)return !bound(t.args[0],truths,known,!upper);const a=bound(t.args[0],truths,known,upper),b=bound(t.args[1],truths,known,upper);return t.op===0?a&&b:a||b;}
let checked=0;
for(let i=0;i<256;i++){const t=tree(4);for(let truths=0;truths<16;truths++)for(let known=0;known<16;known++){
 const full=tri(t,truths,15)===1,allow=tri(t,truths,known)!==0;
 assert(!full||allow,'full implies projected acceptance');
 assert.equal(allow,bound(t,truths,known,true),'three-valued rule equals polarity-aware upper bound');
 checked++;
}}
console.log(`PASS three-valued proposal model: ${checked} tree/assignment/visibility combinations`);
console.log('Scope: Boolean grouping uses actual source with numeric text stubs; projection is a reference model, not the future compiler.');
