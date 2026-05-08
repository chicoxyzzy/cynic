let out = '';
for (let i = 1; i <= 15; i = i + 1) {
  if (i % 15 === 0) out = out + 'FizzBuzz,';
  else if (i % 3 === 0) out = out + 'Fizz,';
  else if (i % 5 === 0) out = out + 'Buzz,';
  else out = out + i + ',';
}
out;
