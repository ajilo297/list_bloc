import 'data_repository.dart';

abstract class ListRepository<T,F> extends DataRepository<List<T>,F>{
  @override
  Future <List<T>> load([F filter]);
}
