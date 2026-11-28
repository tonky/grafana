// jest's --filter module for jest.sh: keeps the test files whose absolute path matches
// JEST_PATHS, the regex jest.sh builds of the component's test paths. --testPathPattern
// would not do: jest drops it under --findRelatedTests and answers from the whole project.
const pattern = new RegExp(process.env.JEST_PATHS || '.');

module.exports = async (paths) => ({
  filtered: paths.filter((path) => pattern.test(path)).map((test) => ({ test })),
});
