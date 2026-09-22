// Run against the pinned, unmodified application source. Only numeric leaf
// rendering is stubbed; Boolean rendering is extracted from the real file.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[3]);
const source = fs.readFileSync(process.argv[2], 'utf8');
const ast = ts.createSourceFile('condition-plan.ts', source, ts.ScriptTarget.Latest, true);
const fn = ast.statements.find(s => ts.isFunctionDeclaration(s) && s.name?.text === 'renderBool');
assert(fn, 'Real renderBool function must exist');
const js = ts.transpileModule(fn.getText(ast), { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
const ctx = { renderNum: n => String(n.value), OP_WORD: { '==': 'equals' } };
vm.createContext(ctx);
vm.runInContext(js, ctx);
const leaf = name => ({ op: 'cmp', cmp: '==', left: { value: name }, right: { value: 1 } });
const A = leaf('A'), B = leaf('B'), C = leaf('C');
const first = { op: 'and', args: [{ op: 'or', args: [A, B] }, C] };
const second = { op: 'or', args: [A, { op: 'and', args: [B, C] }] };
const one = ctx.renderBool(first), two = ctx.renderBool(second);
assert.equal(one, two, 'Different Boolean groupings produce identical current UI text');
const truth = { A: true, B: false, C: false };
const evaluate = n => n.op === 'and' ? n.args.every(evaluate) : n.op === 'or' ? n.args.some(evaluate) : truth[n.left.value];
assert.notEqual(evaluate(first), evaluate(second));
console.log('PASS: actual app Boolean renderer loses AND/OR grouping');
console.log('Both render:', one);
console.log('(A OR B) AND C =', evaluate(first), '; A OR (B AND C) =', evaluate(second));
console.log('Scope: actual renderBool extracted by TypeScript AST; numeric leaf text stubbed; no browser or wallet signing test.');
