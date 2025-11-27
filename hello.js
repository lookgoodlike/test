console.clear();
console.log("document.cookie:");
console.log(document.cookie || "(нет доступных JS cookies)");

console.log("\nРазбивка по ключам:");
(document.cookie || "")
  .split("; ")
  .filter(Boolean)
  .forEach(c => {
    const [name, value] = c.split("=");
    console.log(name, "=", value);
  });
